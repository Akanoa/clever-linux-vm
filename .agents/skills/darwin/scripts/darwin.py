#!/usr/bin/env python3
"""
darwin - mutation-verified TDD orchestration helper.

Agent- and language-agnostic. Stdlib only. The script owns everything that must
be *mechanically true* (worktree isolation, mutation replay, test execution,
claim/verification diffing) so that agent reports can be checked instead of
trusted.

Run `darwin.py --help` for the command list, or read references/protocol.md.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
TAIL = 8000

# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "isolation": "auto",          # auto | herdr | git | none
    "spawn": "auto",              # auto | herdr-agent | herdr | subprocess
    "accept_startup_prompt": True,  # answer a CLI's own "do you trust this folder?"
                                    # prompt for the worktree darwin created
    "bus": "auto",                # auto | herdr | file
    "max_rounds": 3,              # null = let the trend decide, up to hard_round_cap
    "hard_round_cap": 8,
    "escalate_after_fabrications": 2,
    "stall_rounds": 2,            # rounds of no net progress before escalating
    "worktree_root": ".darwin/worktrees",
    "branch_prefix": "darwin",
    "test": {
        "command": None,          # autodetected when null
        "single_command": None,   # e.g. "pytest -q {selector}" - enables targeted verification
        "timeout_sec": 900,
        "verify_targeted": "auto",
        "env": {"PYTHONDONTWRITEBYTECODE": "1"},
    },
    "mutation": {
        "min_mutants": 5,
        "reviewer_min_mutants": 3,
        "require_kill_rate": 1.0,
        "allow_equivalent": True,
    },
    "agents": {
        "implementer": {"provider": "claude", "model": None, "timeout_sec": 3600, "cmd": None},
        "reviewer": {"provider": "claude", "model": None, "timeout_sec": 3600, "cmd": None},
    },
    "guards": {
        "test_path_patterns": ["*test*", "*spec*", "*Test*", "*Spec*", "*__tests__*"],
        "config_patterns": [
            "pytest.ini", "setup.cfg", "tox.ini", "conftest.py", "pyproject.toml",
            "jest.config.*", "vitest.config.*", "jest.setup.*", ".mocharc.*", "karma.conf.*",
            "package.json", "phpunit.xml*", "Cargo.toml", "go.mod", "Makefile", "Rakefile",
            ".rspec", "build.gradle*", "pom.xml", "*.csproj", ".github/workflows/*",
        ],
        "skip_markers": [
            r"@pytest\.mark\.skip", r"@unittest\.skip", r"\bpytest\.skip\(",
            r"\b(it|test|describe|context)\.(skip|todo)\(", r"\bxit\(", r"\bxdescribe\(",
            r"\bt\.Skip\(", r"#\[ignore\]", r"@Ignore\b", r"@Disabled\b",
            r"\bassert\s+True\b", r"\bexpect\(true\)\.toBe\(true\)", r"\bassert\.ok\(true\)",
        ],
    },
}

PROVIDERS = {
    # Best-effort invocations. `args` runs the CLI headless; `interactive_args`
    # is used when the agent is started as a live TUI inside a herdr pane
    # (spawn: "herdr-agent"). Override in darwin.config.json when a CLI changes
    # its flags: agents.<role>.cmd wins over everything here.
    "claude": {"bin": "claude", "args": ["-p", "--dangerously-skip-permissions"],
               "model_args": ["--model", "{model}"], "prompt_mode": "arg",
               "herdr_kind": "claude", "interactive_args": ["--dangerously-skip-permissions"]},
    "codex": {"bin": "codex", "args": ["exec", "--full-auto"],
              "model_args": ["--model", "{model}"], "prompt_mode": "arg",
              "herdr_kind": "codex", "interactive_args": ["--full-auto"]},
    "gemini": {"bin": "gemini", "args": ["-y", "-p"],
               "model_args": ["-m", "{model}"], "prompt_mode": "arg",
               "herdr_kind": "gemini", "interactive_args": ["-y"]},
    "opencode": {"bin": "opencode", "args": ["run"],
                 "model_args": ["-m", "{model}"], "prompt_mode": "arg",
                 "herdr_kind": "opencode", "interactive_args": []},
    "cursor": {"bin": "cursor-agent", "args": ["-p", "--force"],
               "model_args": ["--model", "{model}"], "prompt_mode": "arg",
               "herdr_kind": "cursor", "interactive_args": ["--force"]},
    "amp": {"bin": "amp", "args": ["-x"], "model_args": [], "prompt_mode": "arg",
            "herdr_kind": "amp", "interactive_args": []},
    "crush": {"bin": "crush", "args": ["run", "-q"],
              "model_args": ["-m", "{model}"], "prompt_mode": "arg"},
}

ENV_OVERRIDES = [
    ("DARWIN_ISOLATION", ["isolation"]),
    ("DARWIN_BUS", ["bus"]),
    ("DARWIN_SPAWN", ["spawn"]),
    ("DARWIN_MAX_ROUNDS", ["max_rounds"]),
    ("DARWIN_TEST_CMD", ["test", "command"]),
    ("DARWIN_TEST_SINGLE_CMD", ["test", "single_command"]),
    ("DARWIN_TEST_TIMEOUT", ["test", "timeout_sec"]),
    ("DARWIN_MIN_MUTANTS", ["mutation", "min_mutants"]),
    ("DARWIN_IMPL_PROVIDER", ["agents", "implementer", "provider"]),
    ("DARWIN_IMPL_MODEL", ["agents", "implementer", "model"]),
    ("DARWIN_IMPL_CMD", ["agents", "implementer", "cmd"]),
    ("DARWIN_REVIEWER_PROVIDER", ["agents", "reviewer", "provider"]),
    ("DARWIN_REVIEWER_MODEL", ["agents", "reviewer", "model"]),
    ("DARWIN_REVIEWER_CMD", ["agents", "reviewer", "cmd"]),
]

INT_KEYS = {"max_rounds", "timeout_sec", "min_mutants", "escalate_after_fabrications"}

TEST_DETECTORS = [
    ("package.json", "npm test --silent"),
    ("pnpm-lock.yaml", "pnpm test"),
    ("pyproject.toml", "pytest -q"),
    ("pytest.ini", "pytest -q"),
    ("setup.cfg", "pytest -q"),
    ("Cargo.toml", "cargo test --quiet"),
    ("go.mod", "go test ./..."),
    ("pom.xml", "mvn -q test"),
    ("build.gradle", "gradle test"),
    ("build.gradle.kts", "gradle test"),
    ("Gemfile", "bundle exec rspec"),
    ("composer.json", "composer test"),
    ("mix.exs", "mix test"),
    ("deno.json", "deno test -A"),
]


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def die(msg: str, code: int = 2):
    print(f"darwin: error: {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg: str):
    print(f"darwin: warning: {msg}", file=sys.stderr)


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def set_path(cfg: dict, path, value):
    node = cfg
    for k in path[:-1]:
        node = node.setdefault(k, {})
    key = path[-1]
    if key in INT_KEYS:
        try:
            value = int(value)
        except ValueError:
            pass
    node[key] = value


def read_json(p: Path, default=None):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError:
        if default is not None:
            return default
        die(f"missing file: {p}")
    except json.JSONDecodeError as e:
        die(f"invalid JSON in {p}: {e}")


def write_json(p: Path, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def digest(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def slugify(text: str, limit: int = 32) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", (text or "task").strip().lower()).strip("-")
    return (s[:limit].strip("-") or "task")


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------

def run(cmd, cwd=None, timeout=None, shell=False, stdin_text=None, env=None):
    """Run a command, capture merged output. Returns (exit_code, output, seconds)."""
    started = time.monotonic()
    try:
        proc = subprocess.run(
            cmd, cwd=str(cwd) if cwd else None, shell=shell, timeout=timeout,
            input=stdin_text, text=True, capture_output=True,
            env={**os.environ, **(env or {})},
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out, round(time.monotonic() - started, 2)
    except subprocess.TimeoutExpired as e:
        parts = []
        for stream in (e.stdout, e.stderr):
            if stream:
                parts.append(stream if isinstance(stream, str) else stream.decode("utf-8", "replace"))
        return 124, "".join(parts) + f"\n[darwin] TIMEOUT after {timeout}s", round(time.monotonic() - started, 2)
    except FileNotFoundError as e:
        return 127, f"[darwin] command not found: {e}", 0.0


def git(args, cwd, check=True, timeout=300):
    code, out, _ = run(["git", *args], cwd=cwd, timeout=timeout)
    if check and code != 0:
        die(f"git {' '.join(args)} failed in {cwd}:\n{out.strip()}")
    return code, out


def have(binary: str) -> bool:
    return shutil.which(binary) is not None


def herdr_json(args: list, timeout: int = 120):
    """Run a herdr CLI command and return its `result` object (herdr speaks JSON on stdout)."""
    code, out, _ = run(["herdr", *args], timeout=timeout)
    if code != 0:
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "result" in payload:
                return payload["result"]
            if "error" in payload:
                return None
    return {}  # succeeded, but this subcommand prints nothing


def herdr_workspace_ids() -> set:
    res = herdr_json(["workspace", "list"], timeout=30) or {}
    return {w.get("workspace_id") for w in res.get("workspaces", []) if w.get("workspace_id")}


def herdr_available() -> bool:
    if not have("herdr"):
        return False
    code, _, _ = run(["herdr", "status"], timeout=15)
    return code == 0


# --------------------------------------------------------------------------
# repo / run context
# --------------------------------------------------------------------------

class Ctx:
    def __init__(self, repo: Path, cfg: dict, run_dir: Path | None = None, state: dict | None = None):
        self.repo, self.cfg, self.run_dir, self.state = repo, cfg, run_dir, state

    @property
    def run_id(self) -> str:
        return self.state["run_id"]

    def save(self):
        if self.run_dir and self.state:
            self.state["updated_at"] = now()
            write_json(self.run_dir / "run.json", self.state)

    def round_dir(self, rnd: int, role: str | None = None) -> Path:
        p = self.run_dir / "rounds" / f"r{rnd}"
        return p / role if role else p

    def worktree(self, role: str) -> Path:
        return Path(self.state["roles"][role]["worktree"])


def find_repo(start: Path) -> Path:
    """The *main* repository root, even when called from inside a linked worktree.

    Agents run inside their own worktree but every darwin artefact lives under
    the main checkout, so the common git dir is the anchor, not the toplevel.
    """
    code, out, _ = run(["git", "rev-parse", "--show-toplevel"], cwd=start)
    if code != 0:
        die("not inside a git repository (darwin needs git for worktree isolation)")
    top = Path(out.strip())
    code, common, _ = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=start)
    if code == 0 and common.strip():
        cdir = Path(common.strip())
        if cdir.name == ".git" and cdir.parent.is_dir():
            return cdir.parent
    return top


def load_config(repo: Path, cli_overrides: dict | None = None) -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    for name in ("darwin.config.json", ".darwin/config.json", ".darwin.json"):
        p = repo / name
        if p.exists():
            cfg = deep_merge(cfg, read_json(p))
            cfg["_config_file"] = str(p)
            break
    for env_key, path in ENV_OVERRIDES:
        val = os.environ.get(env_key)
        if val not in (None, ""):
            set_path(cfg, path, val)
    for path, val in (cli_overrides or {}).items():
        if val is not None:
            set_path(cfg, list(path), val)
    if not cfg["test"]["command"]:
        cfg["test"]["command"] = detect_test_command(repo)
    return cfg


def detect_test_command(repo: Path) -> str | None:
    for marker, cmd in TEST_DETECTORS:
        if (repo / marker).exists():
            if marker == "package.json":
                data = read_json(repo / "package.json", default={})
                if "test" not in (data.get("scripts") or {}):
                    continue
            return cmd
    mk = repo / "Makefile"
    if mk.exists() and re.search(r"^test:", mk.read_text(encoding="utf-8", errors="replace"), re.M):
        return "make test"
    return None


def ensure_excluded(repo: Path):
    """Keep .darwin/ out of git without touching the user's .gitignore."""
    code, out = git(["rev-parse", "--git-common-dir"], cwd=repo, check=False)
    common = Path(out.strip() or ".git")
    if not common.is_absolute():
        common = repo / common
    exclude = common / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    body = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
    if ".darwin/" not in body:
        with exclude.open("a", encoding="utf-8") as fh:
            fh.write("\n# added by darwin (mutation-verified TDD)\n.darwin/\n")


def resolve_run(repo: Path, run_id: str | None) -> Path:
    runs = repo / ".darwin" / "runs"
    if run_id:
        p = runs / run_id
        if not p.exists():
            die(f"unknown run: {run_id}")
        return p
    pointer = repo / ".darwin" / "current"
    if pointer.exists():
        p = runs / pointer.read_text(encoding="utf-8").strip()
        if p.exists():
            return p
    candidates = sorted([d for d in runs.glob("*") if (d / "run.json").exists()])
    if not candidates:
        die("no darwin run found - start one with `darwin init`")
    return candidates[-1]


def ctx_for(args, need_run: bool = True) -> Ctx:
    repo = find_repo(Path(args.cwd or os.getcwd()).resolve())
    if not need_run:
        return Ctx(repo, load_config(repo))
    run_dir = resolve_run(repo, getattr(args, "run", None))
    state = read_json(run_dir / "run.json")
    return Ctx(repo, state["config"], run_dir, state)


# --------------------------------------------------------------------------
# isolation: worktrees (herdr when available, plain git otherwise)
# --------------------------------------------------------------------------

def isolation_mode(cfg: dict) -> str:
    mode = cfg.get("isolation", "auto")
    if mode == "auto":
        return "herdr" if herdr_available() else "git"
    if mode == "herdr" and not herdr_available():
        warn("isolation=herdr requested but herdr is unavailable - falling back to git worktree")
        return "git"
    return mode


def worktree_add(ctx: Ctx, role: str, base: str, branch: str, path: Path) -> dict:
    mode = isolation_mode(ctx.cfg)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        die(f"worktree path already exists: {path}")
    used, extra = "git", {}
    if mode == "herdr":
        before = herdr_workspace_ids()
        res = herdr_json(["worktree", "create", "--cwd", str(ctx.repo),
                          "--branch", branch, "--base", base, "--path", str(path),
                          "--label", f"darwin-{role}", "--no-focus"])
        if res is not None and path.exists():
            used = "herdr"
            ws = (res.get("workspace") or {}).get("workspace_id")
            extra = {"workspace_id": ws,
                     "pane_id": (res.get("root_pane") or {}).get("pane_id")}
            # Name the pane as well as labelling it: `pane report-agent` sets the
            # displayed agent label, but only a `name` makes the pane addressable
            # from off the machine. Without this every darwin pane is born
            # nameless and cannot be reached by the fleet API to be read,
            # prompted, or unblocked.
            herdr_name_pane(extra.get("pane_id"), ctx.run_id, role)
            # herdr also opens a workspace for the source repo if none was open;
            # remember it so `clean` does not leave it behind
            aux = [w for w in herdr_workspace_ids() - before if w != ws]
            if aux:
                ctx.state.setdefault("herdr_aux_workspaces", [])
                ctx.state["herdr_aux_workspaces"] += aux
        else:
            warn("herdr worktree create failed; falling back to a plain git worktree")
    if used == "git":
        git(["worktree", "add", "-b", branch, str(path), base], cwd=ctx.repo)
    return {"role": role, "branch": branch, "worktree": str(path), "base": base,
            "isolation": used, **extra}


def worktree_remove(ctx: Ctx, role: str, delete_branch: bool = False):
    info = ctx.state["roles"].get(role)
    if not info:
        return
    path = Path(info["worktree"])
    if info.get("isolation") == "herdr" and info.get("workspace_id"):
        herdr_json(["worktree", "remove", "--workspace", info["workspace_id"], "--force"], timeout=60)
        herdr_json(["workspace", "close", info["workspace_id"]], timeout=60)
    if path.exists():
        git(["worktree", "remove", "--force", str(path)], cwd=ctx.repo, check=False)
        if path.exists():
            shutil.rmtree(path, ignore_errors=True)
    git(["worktree", "prune"], cwd=ctx.repo, check=False)
    if delete_branch:
        git(["branch", "-D", info["branch"]], cwd=ctx.repo, check=False)


# --------------------------------------------------------------------------
# agent launching
# --------------------------------------------------------------------------

BOOTSTRAP = (
    "You are running inside a darwin mutation-verified TDD workflow. "
    "Read the file .darwin/PROMPT.md at the root of this working directory and follow it exactly, "
    "start to finish, without asking for confirmation. It is your complete brief."
)


def build_agent_cmd(cfg: dict, role: str, prompt: str) -> tuple[list, str | None, str]:
    """Returns (argv, stdin_text, provider_label)."""
    spec = cfg["agents"][role]
    if spec.get("cmd"):
        raw = spec["cmd"]
        argv = raw if isinstance(raw, list) else shlex.split(raw)
        argv = [a.replace("{model}", spec.get("model") or "").replace("{prompt}", prompt) for a in argv]
        argv = [a for a in argv if a != ""]
        stdin_text = prompt if not any("{prompt}" in str(a) for a in (raw if isinstance(raw, list) else [raw])) else None
        return argv, stdin_text, "custom"
    provider = spec.get("provider") or "claude"
    tpl = PROVIDERS.get(provider)
    if not tpl:
        die(f"unknown provider '{provider}' - set agents.{role}.cmd in darwin.config.json instead")
    argv = [tpl["bin"], *tpl["args"]]
    if spec.get("model") and tpl["model_args"]:
        argv += [a.replace("{model}", spec["model"]) for a in tpl["model_args"]]
    if tpl["prompt_mode"] == "arg":
        argv.append(prompt)
        return argv, None, provider
    return argv, prompt, provider


def spawn_mode(ctx: Ctx, role: str) -> str:
    mode = ctx.cfg.get("spawn", "auto")
    pane = (ctx.state.get("roles", {}).get(role) or {}).get("pane_id")
    herdr_ok = bool(pane) and herdr_available()
    if mode == "auto":
        return "herdr" if herdr_ok else "subprocess"
    if mode in ("herdr", "herdr-agent") and not herdr_ok:
        warn(f"spawn={mode} requested but {role} has no herdr pane - running the agent as a subprocess")
        return "subprocess"
    return mode


def pane_text(pane: str) -> str:
    """The pane's visible transcript. `pane read` prints terminal text, not JSON."""
    code, out, _ = run(["herdr", "pane", "read", pane], timeout=60)
    return out if code == 0 else ""


STARTUP_PROMPT_PATTERNS = [
    r"trust (this|the) folder", r"Yes, I trust", r"Do you trust", r"trust the files",
]

EXPECTED_ARTIFACT = {"implementer": "MUTATION-REPORT.json", "reviewer": "REVIEW.json"}


def herdr_agent_state(name: str):
    for a in (herdr_json(["agent", "list"]) or {}).get("agents", []):
        if (a.get("name") or a.get("label")) == name:
            return a
    return None


def clear_startup_prompt(ctx: Ctx, name: str, pane: str) -> bool:
    """Answer the agent CLI's own start-up trust prompt, if that is what blocks it.

    The directory in question is a worktree darwin created from the user's own
    repository, and the run already opted into an unattended agent - so this is
    a confirmation, not a decision. Set accept_startup_prompt=false to answer it
    by hand instead (`herdr agent attach darwin-<role>`).
    """
    text = pane_text(pane)
    if not any(re.search(pat, text, re.I) for pat in STARTUP_PROMPT_PATTERNS):
        return False
    if not ctx.cfg.get("accept_startup_prompt", True):
        warn(f"{name} is waiting at a start-up prompt; attach with `herdr agent attach {name}`")
        return False
    print(f"darwin: answering {name}'s start-up trust prompt for its own worktree")
    herdr_json(["agent", "send-keys", name, "Enter"], timeout=30)
    for _ in range(30):
        time.sleep(2)
        state = herdr_agent_state(name)
        if state and not state.get("launch_pending") and state.get("agent_status") != "blocked":
            return True
    return False


def spawn_via_herdr_agent(ctx: Ctx, role: str, wt: Path, log: Path, timeout: int) -> tuple:
    """Start (or reuse) a live agent TUI in the role's herdr pane and prompt it.

    This is the agent-native path: the CLI runs interactively, herdr tracks its
    state, and the run is watchable and attachable while it happens.
    """
    spec = ctx.cfg["agents"][role]
    tpl = PROVIDERS.get(spec.get("provider") or "", {})
    kind = spec.get("herdr_kind") or tpl.get("herdr_kind")
    if not kind:
        return None, f"[darwin] provider {spec.get('provider')} has no herdr agent kind", 0.0
    pane = ctx.state["roles"][role]["pane_id"]
    name = f"darwin-{role}"
    started = time.monotonic()

    listing = herdr_json(["agent", "list"]) or {}
    known = {a.get("name") or a.get("label") for a in listing.get("agents", [])}
    if name not in known:
        args = list(tpl.get("interactive_args", []))
        if spec.get("model") and tpl.get("model_args"):
            args += [a.replace("{model}", spec["model"]) for a in tpl["model_args"]]
        cmd = ["agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", "120000"]
        if args:
            cmd += ["--", *args]
        herdr_json(cmd, timeout=200)
        state = herdr_agent_state(name)
        if state and (state.get("launch_pending") or state.get("agent_status") == "blocked"):
            clear_startup_prompt(ctx, name, pane)
            state = herdr_agent_state(name)
        if not state or state.get("agent_status") in (None, "blocked"):
            return None, f"[darwin] {name} never became ready in pane {pane}", \
                   round(time.monotonic() - started, 2)
        ctx.state["roles"][role]["herdr_agent"] = name
        ctx.save()

    deadline = started + timeout
    artifact = ctx.round_dir(ctx.state.get("round") or 1, role) / EXPECTED_ARTIFACT.get(role, "")
    prompt_text, nudges, res = BOOTSTRAP, 0, None
    while True:
        left = max(60, int(deadline - time.monotonic()))
        # herdr distinguishes idle from done; wait for either, or a settled agent
        # can sit unnoticed until the role's timeout expires
        res = herdr_json(["agent", "prompt", name, prompt_text, "--wait",
                          "--until", "idle", "--until", "done",
                          "--timeout", str(left * 1000)], timeout=left + 120)
        if res is None or artifact.name == "" or artifact.exists() or nudges >= 2 \
                or time.monotonic() >= deadline:
            break
        # herdr reports the first settled state after submission; an agent that
        # goes idle without its deliverable simply is not done yet
        nudges += 1
        print(f"darwin: {name} is idle but {artifact.name} is missing - nudging ({nudges}/2)")
        prompt_text = (f"You have not written {artifact} yet. Re-read .darwin/PROMPT.md "
                       f"and finish the protocol, ending with that file and the msg send.")

    secs = round(time.monotonic() - started, 2)
    text = pane_text(pane)
    if text:
        log.write_text(text, encoding="utf-8")
    if res is None:
        herdr_report(ctx, role, "blocked", "darwin: agent did not settle in time")
        return 124, text or f"[darwin] TIMEOUT waiting for {name} to go idle", secs
    return 0, text, secs


def pane_agent_name(run_id: str, role: str) -> str:
    """A short, stable herdr `name` for a role's pane.

    A pane's `name` is what addresses it from outside the box - the fleet's HTTP
    API resolves agents by name and cannot see a nameless pane at all. herdr's
    *reported agent label* (set by `pane report-agent`) is a separate field and
    does not make a pane addressable, so a spawned role that is only labelled is
    invisible to anything that is not already on the machine.
    """
    tail = run_id.rsplit("-", 1)[-1] or run_id
    name = f"dw-{tail}-{role}"
    return re.sub(r"[^A-Za-z0-9_-]", "-", name)[:32]


def herdr_name_pane(pane: str | None, run_id: str, role: str) -> None:
    """Give a spawned pane a name. Best-effort: never fail a run over cosmetics."""
    if not pane:
        return
    herdr_json(["agent", "rename", pane, pane_agent_name(run_id, role)], timeout=30)


def herdr_report(ctx: Ctx, role: str, state: str, message: str = ""):
    pane = (ctx.state.get("roles", {}).get(role) or {}).get("pane_id")
    if not pane:
        return
    args = ["pane", "report-agent", pane, "--source", "darwin",
            "--agent", f"darwin-{role}", "--state", state]
    if message:
        args += ["--message", message[:200]]
    herdr_json(args, timeout=30)


def spawn_via_herdr(ctx: Ctx, role: str, argv: list, stdin_file: Path | None,
                    wt: Path, log: Path, timeout: int) -> tuple:
    """Run the agent CLI inside the role's persistent herdr pane."""
    pane = ctx.state["roles"][role]["pane_id"]
    # nonce keeps a stale marker from an earlier spawn out of the scrollback match
    nonce = hashlib.sha256(f"{role}{time.time()}".encode()).hexdigest()[:8]
    suffix = f"_DONE_{role}_{nonce}"
    marker = "DARWIN" + suffix
    # the marker is split in the typed line so wait-output cannot match the echo of the command
    shell_cmd = (f"cd {shlex.quote(str(wt))} && {shlex.join(argv)}"
                 + (f" < {shlex.quote(str(stdin_file))}" if stdin_file else "")
                 + f" > {shlex.quote(str(log))} 2>&1; "
                 + f"printf 'DARWIN''{suffix}=%d\\n' $?")
    started = time.monotonic()
    herdr_report(ctx, role, "working", f"darwin round {ctx.state.get('round')}")
    if herdr_json(["pane", "run", pane, shell_cmd], timeout=60) is None:
        return None, "[darwin] herdr pane run failed", 0.0
    res = herdr_json(["pane", "wait-output", pane, "--regex", f"{marker}=[0-9]+",
                      "--timeout", str(int(timeout * 1000))], timeout=timeout + 60)
    secs = round(time.monotonic() - started, 2)
    if res is None:
        herdr_report(ctx, role, "blocked", "darwin: agent did not finish in time")
        return 124, f"[darwin] TIMEOUT waiting for {marker} after {timeout}s", secs
    line = res.get("matched_line", "")
    m = re.search(rf"{marker}=(\d+)", line)
    code = int(m.group(1)) if m else 0
    herdr_report(ctx, role, "idle" if code == 0 else "blocked", f"darwin exit {code}")
    out = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    return code, out, secs


def spawn_agent(ctx: Ctx, role: str, rnd: int, prompt_text: str) -> dict:
    wt = ctx.worktree(role)
    rdir = ctx.round_dir(rnd, role)
    rdir.mkdir(parents=True, exist_ok=True)
    prompt_path = wt / ".darwin" / "PROMPT.md"
    prompt_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt_text, encoding="utf-8")
    (rdir / "PROMPT.md").write_text(prompt_text, encoding="utf-8")

    argv, stdin_text, provider = build_agent_cmd(ctx.cfg, role, BOOTSTRAP)
    if not have(argv[0]) and spawn_mode(ctx, role) != "herdr-agent":
        die(f"agent CLI '{argv[0]}' not on PATH (provider={provider}). "
            f"Install it, or set agents.{role}.cmd in darwin.config.json, "
            f"or set provider to 'inline' and drive the agent yourself with `darwin prompt`")
    spec = ctx.cfg["agents"][role]
    timeout = int(spec.get("timeout_sec") or 3600)
    log = rdir / "agent.log"
    mode = spawn_mode(ctx, role)
    label = f"{provider}{'/' + spec['model'] if spec.get('model') else ''}"
    print(f"darwin: spawning {role} [{label}] via {mode} in {wt}")

    if mode == "herdr-agent":
        code, out, secs = spawn_via_herdr_agent(ctx, role, wt, log, timeout)
        if code is None:
            warn(f"herdr agent start failed ({out.strip()[:200]}) - falling back to a headless pane run")
            mode = "herdr"
    if mode == "herdr":
        stdin_file = None
        if stdin_text is not None:
            stdin_file = wt / ".darwin" / "BOOTSTRAP.txt"
            stdin_file.write_text(stdin_text, encoding="utf-8")
        code, out, secs = spawn_via_herdr(ctx, role, argv, stdin_file, wt, log, timeout)
        if code is None:
            warn("herdr pane run failed - retrying as a subprocess")
            mode = "subprocess"
    if mode == "subprocess":
        code, out, secs = run(argv, cwd=wt, timeout=timeout, stdin_text=stdin_text,
                              env={"DARWIN_RUN_DIR": str(ctx.run_dir), "DARWIN_ROLE": role,
                                   "DARWIN_ROUND": str(rnd), "DARWIN_WORKTREE": str(wt)})
        log.write_text(out, encoding="utf-8")

    result = {"role": role, "round": rnd, "provider": provider, "model": spec.get("model"),
              "spawn_mode": mode, "exit_code": code, "duration_s": secs,
              "log": str(log), "argv": argv}
    write_json(rdir / "spawn.json", result)
    return result


# --------------------------------------------------------------------------
# message bus (files always; herdr used as an optional wake-up signal)
# --------------------------------------------------------------------------

def bus_mode(cfg: dict) -> str:
    mode = cfg.get("bus", "auto")
    if mode == "auto":
        return "herdr" if herdr_available() else "file"
    if mode == "herdr" and not herdr_available():
        warn("bus=herdr requested but herdr is unavailable - falling back to the file bus")
        return "file"
    return mode


def bus_send(ctx: Ctx, sender: str, to: str, mtype: str, body, rnd: int | None = None) -> dict:
    bus = ctx.run_dir / "bus"
    (bus / "inbox" / to).mkdir(parents=True, exist_ok=True)
    log = bus / "messages.jsonl"
    seq = sum(1 for _ in log.open(encoding="utf-8")) + 1 if log.exists() else 1
    msg = {"seq": seq, "ts": now(), "from": sender, "to": to, "type": mtype,
           "round": rnd if rnd is not None else ctx.state.get("round"), "body": body}
    with log.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(msg) + "\n")
    write_json(bus / "inbox" / to / f"{seq:04d}-{mtype}.json", msg)
    if bus_mode(ctx.cfg) == "herdr":
        run(["herdr", "notification", "show", f"darwin {mtype}",
             "--body", f"{sender} -> {to} (run {ctx.run_id})", "--sound", "none"], timeout=15)
        target = ctx.state.get("roles", {}).get(to, {}).get("herdr_agent")
        if target:
            run(["herdr", "agent", "prompt", target,
                 f"darwin: new message #{seq} ({mtype}) in {bus / 'inbox' / to}"], timeout=30)
    return msg


def bus_read(ctx: Ctx, to: str | None = None, mtype: str | None = None, since: int = 0) -> list:
    log = ctx.run_dir / "bus" / "messages.jsonl"
    if not log.exists():
        return []
    msgs = []
    for line in log.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        m = json.loads(line)
        if m["seq"] <= since:
            continue
        if to and m["to"] != to:
            continue
        if mtype and m["type"] != mtype:
            continue
        msgs.append(m)
    return msgs


def bus_wait(ctx: Ctx, to: str, mtype: str | None, timeout: int, since: int = 0, poll: float = 2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = bus_read(ctx, to, mtype, since)
        if found:
            return found[0]
        time.sleep(poll)
    return None


# --------------------------------------------------------------------------
# prompt rendering
# --------------------------------------------------------------------------

def render_prompt(ctx: Ctx, role: str, rnd: int, feedback: str = "") -> str:
    tpl_path = SKILL_ROOT / "agents" / f"{role}.md"
    if not tpl_path.exists():
        die(f"missing agent template: {tpl_path}")
    tpl = tpl_path.read_text(encoding="utf-8")
    task = (ctx.run_dir / "TASK.md").read_text(encoding="utf-8")
    impl = ctx.state["roles"].get("implementer", {})
    subs = {
        "RUN_ID": ctx.run_id,
        "ROUND": str(rnd),
        "MAX_ROUNDS": str(ctx.cfg["max_rounds"]),
        "TASK": task,
        "RUN_DIR": str(ctx.run_dir),
        "ROUND_DIR": str(ctx.round_dir(rnd, role)),
        "WORKTREE": str(ctx.worktree(role)) if role in ctx.state["roles"] else "",
        "REPO": str(ctx.repo),
        "BASE_REF": ctx.state["base_ref"],
        "BASE_COMMIT": ctx.state["base_commit"],
        "TEST_CMD": ctx.cfg["test"]["command"] or "<not configured - detect it yourself and record it>",
        "TEST_SINGLE_CMD": ctx.cfg["test"]["single_command"] or "(not configured)",
        "MIN_MUTANTS": str(ctx.cfg["mutation"]["min_mutants"]),
        "REVIEWER_MIN_MUTANTS": str(ctx.cfg["mutation"].get("reviewer_min_mutants", 3)),
        "DARWIN": str(Path(__file__).resolve()),
        "IMPL_BRANCH": impl.get("branch", ""),
        "IMPL_WORKTREE": impl.get("worktree", ""),
        "IMPL_ROUND_DIR": str(ctx.round_dir(rnd, "implementer")),
        "REVIEW_ROUND_DIR": str(ctx.round_dir(rnd, "reviewer")),
        "FEEDBACK": feedback or "(none - first round)",
    }
    for key, val in subs.items():
        tpl = tpl.replace("{{" + key + "}}", val)
    return tpl


# --------------------------------------------------------------------------
# mutation engine
# --------------------------------------------------------------------------

def tree_clean(wt: Path) -> tuple[bool, str]:
    _, out = git(["status", "--porcelain"], cwd=wt, check=False)
    return (out.strip() == ""), out.strip()


def head_commit(wt: Path) -> str:
    _, out = git(["rev-parse", "HEAD"], cwd=wt, check=False)
    return out.strip()


def revert_tree(wt: Path, files: list | None = None):
    git(["checkout", "--", "."], cwd=wt, check=False)
    bump_mtimes(wt, files or [])


def bump_mtimes(wt: Path, files: list):
    """Push mutated files one second into the future.

    Build and bytecode caches key on whole-second mtimes; a mutate-test-revert
    cycle can finish inside one second, which leaves a stale artefact compiled
    from the mutant and makes the next run lie.
    """
    stamp = time.time() + 1.0
    for rel in files:
        target = wt / rel
        if target.exists():
            os.utime(target, (stamp, stamp))


def apply_mutant(wt: Path, patch: Path):
    """Apply a mutant patch. Returns (ok, output, touched_files)."""
    files = patch_files(patch.read_text(encoding="utf-8", errors="replace"))
    code, out = git(["apply", "--whitespace=nowarn", str(patch)], cwd=wt, check=False)
    if code == 0:
        bump_mtimes(wt, files)
    return code == 0, out, files


def is_test_path(path: str, cfg: dict) -> bool:
    pats = cfg["guards"]["test_path_patterns"]
    return any(fnmatch.fnmatch(path, p) or fnmatch.fnmatch(Path(path).name, p) for p in pats)


def patch_files(patch_text: str) -> list:
    return sorted(set(re.findall(r"^\+\+\+ b/(.+)$", patch_text, re.M)))


def run_tests(cfg: dict, wt: Path, command: str | None = None, selector: str | None = None) -> dict:
    cmd = command or cfg["test"]["command"]
    if selector is not None:
        tpl = cfg["test"]["single_command"]
        cmd = tpl.replace("{selector}", selector) if tpl else cmd
    if not cmd:
        die("no test command configured (set test.command in darwin.config.json or DARWIN_TEST_CMD)")
    timeout = int(cfg["test"]["timeout_sec"] or 900)
    code, out, secs = run(cmd, cwd=wt, shell=True, timeout=timeout,
                          env={k: str(v) for k, v in (cfg["test"].get("env") or {}).items()})
    return {
        "command": cmd, "exit_code": code, "duration_s": secs,
        "timed_out": code == 124, "output_tail": out[-TAIL:], "output_digest": digest(out),
    }


def mutant_status(result: dict) -> str:
    if result["timed_out"]:
        return "TIMEOUT"
    return "KILLED" if result["exit_code"] != 0 else "SURVIVED"


def cmd_mutant_capture(args):
    ctx = ctx_for(args)
    role, rnd = args.role, args.round or ctx.state["round"] or 1
    wt = ctx.worktree(role)
    _, diff = git(["diff", "--binary"], cwd=wt, check=False)
    if not diff.strip():
        die("no working-tree changes to capture - edit the production code first, then capture")
    touched = patch_files(diff)
    bad = [f for f in touched if is_test_path(f, ctx.cfg)]
    if bad:
        die(f"mutant would modify test files {bad} - mutants must alter production code only "
            f"(your edit is left in place so you can fix it)")
    mdir = ctx.round_dir(rnd, role) / "mutants"
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / f"{args.id}.patch").write_text(diff, encoding="utf-8")
    meta = {
        "id": args.id, "patch": f"mutants/{args.id}.patch", "target_files": touched,
        "target_symbol": args.symbol, "operator": args.operator, "intent": args.intent,
        "expected_killers": [s for s in (args.expected_killers or "").split(",") if s.strip()],
        "captured_at": now(),
    }
    write_json(mdir / f"{args.id}.json", meta)
    if not args.keep:
        revert_tree(wt)
    print(json.dumps({"captured": args.id, "files": touched,
                      "patch": str(mdir / f"{args.id}.patch"), "reverted": not args.keep}, indent=2))


def cmd_mutant_run(args):
    ctx = ctx_for(args)
    role, rnd = args.role, args.round or ctx.state["round"] or 1
    wt = ctx.worktree(role)
    mdir = ctx.round_dir(rnd, role) / "mutants"
    clean, dirty = tree_clean(wt)
    if not clean:
        die(f"worktree is dirty, refusing to run mutants:\n{dirty}")
    ids = [args.id] if args.id else sorted(p.stem for p in mdir.glob("*.json") if not p.name.endswith(".result.json"))
    if not ids:
        die(f"no mutants found in {mdir}")
    results = []
    for mid in ids:
        meta = read_json(mdir / f"{mid}.json")
        patch = mdir / f"{mid}.patch"
        ok, out, files = apply_mutant(wt, patch)
        if not ok:
            res = {"id": mid, "applied": False, "error": out.strip()[:1000]}
            revert_tree(wt, files)
        else:
            full = run_tests(ctx.cfg, wt)
            res = {"id": mid, "applied": True, "status": mutant_status(full), "full_suite": full}
            if ctx.cfg["test"]["single_command"] and meta.get("expected_killers"):
                res["targeted"] = [
                    {"selector": sel, **run_tests(ctx.cfg, wt, selector=sel)}
                    for sel in meta["expected_killers"]
                ]
            revert_tree(wt, files)
        res["measured_at"] = now()
        write_json(mdir / f"{mid}.result.json", res)
        results.append(res)
        print(f"  {mid}: {res.get('status', 'NOT_APPLIED')}")
    clean, dirty = tree_clean(wt)
    if not clean:
        warn(f"worktree left dirty after mutant runs:\n{dirty}")
    print(json.dumps({"ran": len(results),
                      "killed": sum(1 for r in results if r.get("status") == "KILLED")}, indent=2))


def cmd_report_build(args):
    ctx = ctx_for(args)
    role, rnd = args.role, args.round or ctx.state["round"] or 1
    wt, rdir = ctx.worktree(role), ctx.round_dir(rnd, role)
    mdir = rdir / "mutants"
    mutants = []
    for meta_path in sorted(mdir.glob("*.json")):
        if meta_path.name.endswith(".result.json"):
            continue
        meta = read_json(meta_path)
        res_path = mdir / f"{meta['id']}.result.json"
        res = read_json(res_path, default={}) if res_path.exists() else {}
        claimed = {"status": res.get("status", "UNMEASURED"),
                   "exit_code": (res.get("full_suite") or {}).get("exit_code"),
                   "output_digest": (res.get("full_suite") or {}).get("output_digest")}
        mutants.append({**meta, "claimed": claimed})
    baseline = run_tests(ctx.cfg, wt) if args.baseline else None
    _, names = git(["diff", "--name-status", f"{ctx.state['base_commit']}..HEAD"], cwd=wt, check=False)
    changed = [ln.split("\t") for ln in names.strip().splitlines() if ln.strip()]
    report = {
        "run_id": ctx.run_id, "round": rnd, "role": role, "generated_at": now(),
        "branch": ctx.state["roles"][role]["branch"], "head_commit": head_commit(wt),
        "base_commit": ctx.state["base_commit"],
        "test": {"command": ctx.cfg["test"]["command"], "single_command": ctx.cfg["test"]["single_command"],
                 "baseline": baseline},
        "changed_files": [{"status": c[0], "path": c[-1]} for c in changed],
        "tests_added": [], "red_evidence": [], "mutants": mutants,
        "summary": {"total": len(mutants),
                    "claimed_killed": sum(1 for m in mutants if m["claimed"]["status"] == "KILLED"),
                    "claimed_survived": sum(1 for m in mutants if m["claimed"]["status"] == "SURVIVED")},
        "narrative": "TODO: fill in tests_added, red_evidence and narrative before submitting",
    }
    out = rdir / "MUTATION-REPORT.json"
    if out.exists() and not args.force:
        die(f"{out} already exists (use --force to regenerate the measured skeleton)")
    write_json(out, report)
    print(f"wrote {out}  ({report['summary']['total']} mutants)")


# --------------------------------------------------------------------------
# independent verification
# --------------------------------------------------------------------------

def collect_guards(ctx: Ctx, wt: Path, report: dict, mutants_dir: Path, verified: list) -> list:
    g, cfg = [], ctx.cfg

    def add(code, severity, detail):
        g.append({"code": code, "severity": severity, "detail": detail})

    clean, dirty = tree_clean(wt)
    if not clean:
        add("G_DIRTY_TREE", "block", f"worktree not clean before verification:\n{dirty[:1000]}")
    actual_head = head_commit(wt)
    if report.get("head_commit") and report["head_commit"] != actual_head:
        add("G_HEAD_MISMATCH", "block",
            f"report claims HEAD {report['head_commit'][:12]} but worktree is at {actual_head[:12]}")
    if report.get("test", {}).get("command") and cfg["test"]["command"] and \
            report["test"]["command"] != cfg["test"]["command"]:
        add("G_TEST_CMD_CHANGED", "block",
            f"report ran '{report['test']['command']}' but the configured suite is '{cfg['test']['command']}'")

    _, names = git(["diff", "--name-status", f"{ctx.state['base_commit']}..{actual_head}"], cwd=wt, check=False)
    rows = [ln.split("\t") for ln in names.strip().splitlines() if ln.strip()]
    changed = [(r[0], r[-1]) for r in rows]
    test_changes = [(s, p) for s, p in changed if is_test_path(p, cfg)]
    if not test_changes:
        add("G_NO_TEST_CHANGES", "block", "no test file was added or modified - TDD requires tests first")
    deleted_tests = [p for s, p in test_changes if s.startswith(("D", "R"))]
    if deleted_tests:
        add("G_TEST_REMOVED", "block", f"test files deleted or renamed since base: {deleted_tests}")
    touched_cfg = [p for _, p in changed
                   if any(fnmatch.fnmatch(p, pat) or fnmatch.fnmatch(Path(p).name, pat)
                          for pat in cfg["guards"]["config_patterns"])]
    if touched_cfg:
        add("G_TEST_CONFIG_TOUCHED", "warn",
            f"test/build configuration modified - confirm it does not weaken the suite: {touched_cfg}")

    _, diff = git(["diff", f"{ctx.state['base_commit']}..{actual_head}"], cwd=wt, check=False)
    added = "\n".join(ln[1:] for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++"))
    hits = sorted({pat for pat in cfg["guards"]["skip_markers"] if re.search(pat, added)})
    if hits:
        add("G_SKIP_MARKERS", "warn", f"added lines match skip/no-op assertion patterns: {hits}")

    for m in report.get("mutants", []):
        p = mutants_dir / Path(m.get("patch", "")).name
        if not p.exists():
            add("G_MUTANT_MISSING", "block", f"mutant {m['id']} has no patch file at {p}")
            continue
        bad = [f for f in patch_files(p.read_text(encoding="utf-8")) if is_test_path(f, cfg)]
        if bad:
            add("G_MUTANT_TOUCHES_TESTS", "block", f"mutant {m['id']} modifies test files {bad}")

    total = len(verified)
    if total < int(cfg["mutation"]["min_mutants"]):
        add("G_TOO_FEW_MUTANTS", "block",
            f"{total} mutants submitted, minimum is {cfg['mutation']['min_mutants']}")
    survivors = [v["id"] for v in verified if v.get("status") == "SURVIVED"]
    justified = ({m["id"] for m in report.get("mutants", []) if m.get("equivalent_justification")}
                 if cfg["mutation"].get("allow_equivalent", True) else set())
    unjustified = [s for s in survivors if s not in justified]
    if unjustified:
        add("G_SURVIVORS", "block",
            f"mutants survived the suite with no equivalence justification: {unjustified}")
    required = float(cfg["mutation"].get("require_kill_rate", 1.0))
    killed_now = sum(1 for v in verified if v.get("status") in ("KILLED", "TIMEOUT"))
    rate = killed_now / total if total else 0.0
    if total and rate < required:
        add("G_KILL_RATE", "block",
            f"kill rate {rate:.2f} is below the required {required:.2f} "
            f"({killed_now} of {total} mutants killed)")
    if not report.get("tests_added"):
        add("G_REPORT_INCOMPLETE", "block", "the report lists no tests_added - it was not authored, only generated")
    elif str(report.get("narrative", "")).strip().upper().startswith("TODO"):
        add("G_REPORT_INCOMPLETE", "block", "the report still carries the generated TODO narrative placeholder")
    elif not report.get("red_evidence"):
        add("G_REPORT_NO_RED_EVIDENCE", "warn", "no red_evidence recorded - nothing shows the tests preceded the code")

    misses = [v["id"] for v in verified if v.get("targeted_discrepancy") == "named_killer_does_not_kill"]
    if misses:
        add("G_NAMED_KILLER_MISS", "block",
            f"the tests named as killers do not fail on these mutants: {misses} - "
            f"the suite goes red for some other reason, so the specific proof is missing")
    not_applied = [v["id"] for v in verified if not v.get("applied")]
    if not_applied:
        add("G_MUTANT_NOT_APPLICABLE", "block", f"mutant patches failed to apply: {not_applied}")
    return g


def verify_report(ctx: Ctx, role: str, rnd: int, report_path: Path, verifier: str) -> dict:
    report = read_json(report_path)
    wt = ctx.worktree(role)
    mutants_dir = report_path.parent / "mutants"
    # every file any mutant touches, so the baseline cannot read a build artefact
    # left behind by an earlier mutate-revert cycle
    touched = sorted({f for m in report.get("mutants", [])
                      for f in (m.get("target_files") or [])})
    clean, dirty = tree_clean(wt)
    if not clean:
        revert_tree(wt, touched)
        clean, dirty = tree_clean(wt)
    else:
        bump_mtimes(wt, touched)
    baseline = run_tests(ctx.cfg, wt)
    verified = []
    for m in report.get("mutants", []):
        mid = m["id"]
        patch = mutants_dir / Path(m.get("patch", f"mutants/{mid}.patch")).name
        entry = {"id": mid, "operator": m.get("operator"), "intent": m.get("intent"),
                 "target_files": m.get("target_files"), "claimed": (m.get("claimed") or {}).get("status")}
        if not patch.exists():
            entry.update({"applied": False, "status": "NO_PATCH", "discrepancy": "missing_patch"})
            verified.append(entry)
            continue
        ok, out, files = apply_mutant(wt, patch)
        if not ok:
            revert_tree(wt, files)
            entry.update({"applied": False, "status": "NOT_APPLICABLE",
                          "error": out.strip()[:800], "discrepancy": "patch_does_not_apply"})
            verified.append(entry)
            continue
        full = run_tests(ctx.cfg, wt)
        status = mutant_status(full)
        entry.update({"applied": True, "status": status, "exit_code": full["exit_code"],
                      "duration_s": full["duration_s"], "output_tail": full["output_tail"][-2000:]})
        if ctx.cfg["test"]["single_command"] and m.get("expected_killers") and \
                ctx.cfg["test"].get("verify_targeted") in (True, "auto"):
            entry["targeted"] = []
            for sel in m["expected_killers"]:
                t = run_tests(ctx.cfg, wt, selector=sel)
                entry["targeted"].append({"selector": sel, "exit_code": t["exit_code"],
                                          "kills": t["exit_code"] != 0})
            if entry["targeted"] and not any(t["kills"] for t in entry["targeted"]):
                entry["targeted_discrepancy"] = "named_killer_does_not_kill"
        revert_tree(wt, files)
        claimed = entry["claimed"]
        if claimed == "KILLED" and status == "SURVIVED":
            entry["discrepancy"] = "fabricated_kill"
        elif claimed == "SURVIVED" and status == "KILLED":
            entry["discrepancy"] = "understated_kill"
        elif claimed and claimed not in ("UNMEASURED", status):
            entry["discrepancy"] = f"claim_{claimed}_vs_actual_{status}"
        else:
            entry["discrepancy"] = None
        entry["matches_claim"] = entry["discrepancy"] is None and not entry.get("targeted_discrepancy")
        verified.append(entry)

    guards = collect_guards(ctx, wt, report, mutants_dir, verified)
    if baseline["exit_code"] != 0:
        guards.insert(0, {"code": "G_BASELINE_NOT_GREEN", "severity": "block",
                          "detail": f"suite fails on the unmutated tree (exit {baseline['exit_code']}):\n"
                                    + baseline["output_tail"][-1200:]})
    killed = sum(1 for v in verified if v.get("status") in ("KILLED", "TIMEOUT"))
    total = len(verified)
    out = {
        "run_id": ctx.run_id, "round": rnd, "role": role, "verifier": verifier,
        "verified_at": now(), "head_commit": head_commit(wt),
        "baseline": {k: baseline[k] for k in
                     ("command", "exit_code", "duration_s", "output_digest", "output_tail")},
        "mutants": verified, "guards": guards,
        "summary": {
            "total": total, "killed": killed,
            "survived": sum(1 for v in verified if v.get("status") == "SURVIVED"),
            "not_applicable": sum(1 for v in verified if not v.get("applied")),
            "kill_rate": round(killed / total, 3) if total else 0.0,
            "claim_mismatches": [v["id"] for v in verified if not v.get("matches_claim", False)],
            "named_killer_misses": [v["id"] for v in verified if v.get("targeted_discrepancy")],
            "fabricated_kills": [v["id"] for v in verified if v.get("discrepancy") == "fabricated_kill"],
            "blocking_guards": [g["code"] for g in guards if g["severity"] == "block"],
        },
    }
    return out


def cmd_verify(args):
    ctx = ctx_for(args)
    role, rnd = args.role, args.round or ctx.state["round"] or 1
    report_path = Path(args.report) if args.report else ctx.round_dir(rnd, role) / "MUTATION-REPORT.json"
    result = verify_report(ctx, role, rnd, report_path, verifier=args.verifier)
    out = Path(args.out) if args.out else ctx.round_dir(rnd, role) / f"verify.{args.verifier}.json"
    write_json(out, result)
    print(json.dumps({"verify": str(out), **result["summary"]}, indent=2))


# --------------------------------------------------------------------------
# live view
# --------------------------------------------------------------------------

def register_orchestrator(ctx: Ctx, state: str, message: str = ""):
    """If the orchestrator itself runs inside a herdr pane, show it as one."""
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane or not have("herdr"):
        return
    args = ["pane", "report-agent", pane, "--source", "darwin",
            "--agent", "darwin-orchestrator", "--state", state]
    if message:
        args += ["--message", message[:200]]
    herdr_json(args, timeout=30)


def board(ctx: Ctx) -> str:
    """One frame of the run's live status board."""
    state = read_json(ctx.run_dir / "run.json")
    cfg = state["config"]
    agents = {}
    if have("herdr"):
        for a in (herdr_json(["agent", "list"], timeout=20) or {}).get("agents", []):
            agents[a.get("name") or a.get("label")] = a.get("agent_status")
    out = [f"\033[1mdarwin\033[0m  {state['run_id']}",
           f"status {state['status']}   round {state['round']}/{cfg['max_rounds']}   "
           f"base {state['base_commit'][:8]}   {now()}", ""]

    out.append("\033[1mroles\033[0m")
    for role in ("implementer", "reviewer"):
        info = state["roles"].get(role)
        if not info:
            out.append(f"  {role:12} -")
            continue
        spec = cfg["agents"][role]
        model = f"{spec.get('provider')}/{spec.get('model') or 'default'}"
        live = agents.get(f"darwin-{role}", "-")
        out.append(f"  {role:12} {model:22} {info.get('pane_id', '-'):8} {live:8} {info['branch']}")
    out.append("")

    rounds = sorted((ctx.run_dir / "rounds").glob("r*")) if (ctx.run_dir / "rounds").exists() else []
    for rdir in rounds:
        out.append(f"\033[1m{rdir.name}\033[0m")
        rep = read_json(rdir / "implementer" / "MUTATION-REPORT.json", default={})
        if rep:
            sm = rep.get("summary", {})
            out.append(f"  report        {sm.get('total', 0)} mutants, {sm.get('claimed_killed', 0)} claimed killed")
        for verifier in ("orchestrator", "reviewer"):
            for where in (rdir / "implementer", rdir / "reviewer"):
                v = read_json(where / f"verify.{verifier}.json", default={})
                if not v:
                    continue
                vs = v["summary"]
                flags = []
                if vs.get("fabricated_kills"):
                    flags.append(f"FABRICATED {vs['fabricated_kills']}")
                if vs.get("named_killer_misses"):
                    flags.append(f"killer-miss {vs['named_killer_misses']}")
                if vs.get("blocking_guards"):
                    flags.append(",".join(vs["blocking_guards"]))
                out.append(f"  verify/{verifier:<11} {vs['killed']}/{vs['total']} killed"
                           + (f"   \033[31m{' | '.join(flags)}\033[0m" if flags else "   clean"))
                break
        rev = read_json(rdir / "reviewer" / "REVIEW.json", default={})
        if rev:
            adv = rev.get("adversarial_mutants") or []
            survived = [a.get("id") for a in adv if (a.get("observed") or {}).get("status") == "SURVIVED"]
            out.append(f"  review        {rev.get('verdict')}   {len(adv)} adversarial, "
                       f"{len(survived)} survived   {len(rev.get('dishonesty_findings') or [])} dishonesty findings")
        jud = read_json(rdir / "judgment.json", default={})
        if jud:
            out.append(f"  judgment      {jud.get('recommendation')}"
                       + (f" (recorded {jud['recorded_verdict']})" if jud.get("recorded_verdict") else "")
                       + f"   {len(jud.get('blocking') or [])} blocking")
        out.append("")

    msgs = bus_read(ctx)[-6:]
    if msgs:
        out.append("\033[1mbus\033[0m")
        for m in msgs:
            out.append(f"  #{m['seq']:<3} {m['from']:>12} -> {m['to']:<12} {m['type']}")
    return "\n".join(out)


def cmd_watch(args):
    ctx = ctx_for(args)
    if args.once:
        print(board(ctx))
        return
    try:
        while True:
            ctx.state = read_json(ctx.run_dir / "run.json")
            sys.stdout.write("\033[H\033[J" + board(ctx) + "\n")
            sys.stdout.flush()
            if ctx.state["status"] in ("passed", "escalated") and not args.follow:
                return
            time.sleep(max(1, int(args.interval)))
    except KeyboardInterrupt:
        return


def cmd_ui(args):
    """Give the run itself a herdr workspace, so the loop is visible too."""
    ctx = ctx_for(args)
    if not herdr_available():
        warn("herdr is not running - showing the board here instead")
        args.once, args.follow, args.interval = False, True, 3
        return cmd_watch(args)
    cmd = (f"{shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} "
           f"--cwd {shlex.quote(str(ctx.repo))} watch --run {shlex.quote(ctx.run_id)} --follow")
    existing = ctx.state.get("ui")
    if existing and existing.get("pane_id"):
        herdr_json(["pane", "run", existing["pane_id"], cmd], timeout=60)
        herdr_json(["workspace", "focus", existing["workspace_id"]], timeout=30)
        print(json.dumps(existing, indent=2))
        return
    res = herdr_json(["workspace", "create", "--cwd", str(ctx.repo),
                      "--label", f"darwin-run", "--no-focus"], timeout=60)
    if not res:
        die("could not create a herdr workspace for the run")
    ws = (res.get("workspace") or {}).get("workspace_id")
    pane = (res.get("root_pane") or {}).get("pane_id")
    herdr_json(["pane", "rename", pane, f"darwin {ctx.run_id}"], timeout=30)
    herdr_json(["pane", "run", pane, cmd], timeout=60)
    herdr_json(["pane", "report-agent", pane, "--source", "darwin",
                "--agent", "darwin-run", "--state", "working",
                "--message", f"round {ctx.state['round']}"], timeout=30)
    ctx.state["ui"] = {"workspace_id": ws, "pane_id": pane}
    ctx.state.setdefault("herdr_aux_workspaces", [])
    if ws and ws not in ctx.state["herdr_aux_workspaces"]:
        ctx.state["herdr_aux_workspaces"].append(ws)
    ctx.save()
    print(json.dumps(ctx.state["ui"], indent=2))


# --------------------------------------------------------------------------
# judgment
# --------------------------------------------------------------------------

def fingerprint(text: str, keep: int = 64) -> str:
    """Collapse a finding to something comparable across rounds."""
    return re.sub(r"[^a-z0-9]+", " ", str(text or "").lower()).strip()[:keep]


def round_facts(ctx: Ctx, rnd: int) -> dict:
    rep = read_json(ctx.round_dir(rnd, "implementer") / "MUTATION-REPORT.json", default={})
    ver = read_json(ctx.round_dir(rnd, "implementer") / "verify.orchestrator.json", default={})
    rev = read_json(ctx.round_dir(rnd, "reviewer") / "REVIEW.json", default={})
    surv = [a for a in (rev.get("adversarial_mutants") or [])
            if (a.get("observed") or {}).get("status") == "SURVIVED"]
    in_task = [a for a in surv if (a.get("scope") or "in-task") == "in-task"]
    grades = [m.get("quality") for m in (rev.get("mutant_findings") or [])]
    strong = sum(1 for g in grades if g == "strong")
    return {
        "round": rnd,
        "mutants": (rep.get("summary") or {}).get("total", 0),
        "kill_rate": (ver.get("summary") or {}).get("kill_rate", 0.0),
        "fabrications": (ver.get("summary") or {}).get("fabricated_kills") or [],
        "blocking_guards": (ver.get("summary") or {}).get("blocking_guards") or [],
        "verdict": (rev.get("verdict") or "").upper(),
        "in_task": {fingerprint(a.get("intent")): a.get("id") for a in in_task},
        "beyond": {fingerprint(a.get("intent")): a.get("id") for a in surv if a not in in_task},
        "gaps": sorted({fingerprint(g) for g in (rev.get("coverage_gaps") or [])}),
        "strong_ratio": round(strong / len(grades), 2) if grades else None,
    }


def analyse_trend(rounds: list) -> dict:
    """What the sequence of rounds says, as opposed to the latest one.

    Three shapes matter. Findings that keep coming back mean the implementer is
    not acting on them. Findings that get closed while new ones appear mean the
    loop is working. Findings that are all out of scope mean the reviewer has run
    out of task and is now designing features.
    """
    if not rounds:
        return {"shape": "unknown", "detail": []}
    now = rounds[-1]
    prev = rounds[-2] if len(rounds) > 1 else None
    out = {"shape": "first-round", "detail": [], "repeated": [], "closed": [], "new": [],
           "quality_delta": None, "stalled": 0}
    if not prev:
        return out

    repeated = sorted(set(now["in_task"]) & set(prev["in_task"]))
    closed = sorted(set(prev["in_task"]) - set(now["in_task"]))
    fresh = sorted(set(now["in_task"]) - set(prev["in_task"]))
    out["repeated"] = [now["in_task"][k] for k in repeated]
    out["closed"] = [prev["in_task"][k] for k in closed]
    out["new"] = [now["in_task"][k] for k in fresh]
    if now["strong_ratio"] is not None and prev["strong_ratio"] is not None:
        out["quality_delta"] = round(now["strong_ratio"] - prev["strong_ratio"], 2)

    gaps_repeated = sorted(set(now["gaps"]) & set(prev["gaps"]))
    progressed = bool(closed) or now["mutants"] > prev["mutants"] or (out["quality_delta"] or 0) > 0

    stalled = 0
    for a, b in zip(rounds[1:], rounds[:-1]):
        same = set(a["in_task"]) & set(b["in_task"])
        moved = (set(b["in_task"]) - set(a["in_task"])) or a["mutants"] > b["mutants"]
        stalled = stalled + 1 if (same and not moved) else 0
    out["stalled"] = stalled

    if not now["in_task"] and not now["blocking_guards"] and not now["fabrications"]:
        out["shape"] = "converged"
        if now["beyond"]:
            out["detail"].append(f"remaining survivors are all beyond the task: {sorted(now['beyond'].values())}")
    elif repeated and not progressed:
        out["shape"] = "recurring"
        out["detail"].append(f"the same findings came back untouched: {out['repeated']}")
    elif repeated and progressed:
        out["shape"] = "partial"
        out["detail"].append(f"closed {out['closed']}, but {out['repeated']} is still open")
    elif progressed:
        out["shape"] = "converging"
        out["detail"].append(f"closed {out['closed']}; the reviewer moved on to {out['new']}")
    else:
        out["shape"] = "flat"
        out["detail"].append("nothing closed and nothing new - the round changed nothing")
    if gaps_repeated:
        out["detail"].append(f"{len(gaps_repeated)} coverage gap(s) reported in consecutive rounds")
    return out


def cmd_judge(args):
    ctx = ctx_for(args)
    rnd = args.round or ctx.state["round"] or 1
    impl_dir, rev_dir = ctx.round_dir(rnd, "implementer"), ctx.round_dir(rnd, "reviewer")
    report = read_json(impl_dir / "MUTATION-REPORT.json", default={})
    orch = read_json(impl_dir / "verify.orchestrator.json", default={})
    rev_verify = read_json(rev_dir / "verify.reviewer.json", default={})
    review = read_json(rev_dir / "REVIEW.json", default={})

    reasons, blocking = [], []
    if not report:
        blocking.append("implementer produced no MUTATION-REPORT.json")
    if not orch:
        blocking.append("no orchestrator verification (run `darwin verify --role implementer`)")

    osum = orch.get("summary", {})
    if osum.get("fabricated_kills"):
        blocking.append(f"fabricated kills: {osum['fabricated_kills']} - report claims KILLED, replay says SURVIVED")
    if osum.get("claim_mismatches"):
        reasons.append(f"claim mismatches: {osum['claim_mismatches']}")
    for g in orch.get("guards", []):
        (blocking if g["severity"] == "block" else reasons).append(f"{g['code']}: {g['detail'][:300]}")

    disagreements = []
    if rev_verify:
        rmap = {m["id"]: m.get("status") for m in rev_verify.get("mutants", [])}
        for m in orch.get("mutants", []):
            other = rmap.get(m["id"])
            if other and other != m.get("status"):
                disagreements.append({"id": m["id"], "orchestrator": m.get("status"), "reviewer": other})
        if disagreements:
            reasons.append(f"verifier disagreement (possible flaky suite): {disagreements}")

    verdict_of_review = (review.get("verdict") or "").upper()
    if verdict_of_review == "DISPUTE":
        blocking.append("reviewer DISPUTES the report: " + (review.get("summary", "")[:400] or "see REVIEW.json"))
    for f in review.get("dishonesty_findings", []) or []:
        blocking.append(f"reviewer dishonesty finding [{f.get('kind')}]: {str(f.get('evidence'))[:300]}")
    adv_survivors = [a for a in (review.get("adversarial_mutants") or [])
                     if (a.get("observed") or {}).get("status") == "SURVIVED"]
    # a mutant can always be made deeper; only the ones aimed at behaviour the task
    # actually asked for are evidence of a gap rather than a feature request
    in_task = [a for a in adv_survivors if (a.get("scope") or "in-task") == "in-task"]
    beyond = [a for a in adv_survivors if a not in in_task]
    if in_task:
        blocking.append("reviewer's adversarial mutants survived (tests miss real defects): "
                        + ", ".join(f"{a.get('id')}:{a.get('intent', '')[:60]}" for a in in_task))
    if beyond:
        reasons.append("survived, but the reviewer marked them beyond the task's scope - "
                       "these are feature requests, not coverage gaps: "
                       + ", ".join(f"{a.get('id')}:{a.get('intent', '')[:60]}" for a in beyond))
    for gap in review.get("coverage_gaps", []) or []:
        reasons.append(f"coverage gap: {str(gap)[:200]}")

    history = ctx.state.get("history", [])
    fabrication_rounds = sum(1 for h in history if h.get("fabrications")) + (1 if osum.get("fabricated_kills") else 0)
    disagreement_rounds = sum(1 for h in history if h.get("disagreements")) + (1 if disagreements else 0)

    facts = [round_facts(ctx, n) for n in range(1, rnd + 1)]
    trend = analyse_trend([f for f in facts if f["mutants"] or f["verdict"]])

    escalate_reasons = []
    if fabrication_rounds >= int(ctx.cfg["escalate_after_fabrications"]):
        escalate_reasons.append(f"{fabrication_rounds} rounds contained fabricated results")
    cap = ctx.cfg.get("max_rounds")
    if cap and rnd >= int(cap) and blocking:
        escalate_reasons.append(f"round {rnd} of {cap} still blocking")
    if rnd >= int(ctx.cfg.get("hard_round_cap") or 8) and blocking:
        escalate_reasons.append(f"hard cap of {ctx.cfg.get('hard_round_cap')} rounds reached")
    if disagreement_rounds >= 2:
        escalate_reasons.append("two rounds where independent verifications disagreed - suite is likely non-deterministic")
    if trend["shape"] == "recurring":
        escalate_reasons.append("the same findings are being reported round after round with nothing "
                                "closed - the implementer is not acting on the review: "
                                + "; ".join(trend["detail"]))
    if trend.get("stalled", 0) >= int(ctx.cfg.get("stall_rounds") or 2):
        escalate_reasons.append(f"{trend['stalled']} consecutive rounds with no net progress")

    if escalate_reasons:
        recommendation = "ESCALATE"
    elif blocking:
        recommendation = "REVISE"
    else:
        recommendation = "PASS"

    judgment = {
        "run_id": ctx.run_id, "round": rnd, "judged_at": now(),
        "recommendation": recommendation,
        "blocking": blocking, "notes": reasons, "escalate_reasons": escalate_reasons,
        "trend": trend, "round_facts": facts,
        "facts": {
            "implementer_summary": report.get("summary"),
            "orchestrator_verification": osum,
            "reviewer_verification": rev_verify.get("summary"),
            "reviewer_verdict": verdict_of_review or None,
            "verifier_disagreements": disagreements,
            "adversarial_survivors": [a.get("id") for a in adv_survivors],
            "adversarial_survivors_in_task": [a.get("id") for a in in_task],
            "adversarial_survivors_beyond_task": [a.get("id") for a in beyond],
        },
        "recorded_verdict": args.record.upper() if args.record else None,
        "recorded_reason": args.reason,
    }
    write_json(ctx.round_dir(rnd) / "judgment.json", judgment)
    register_orchestrator(ctx, "blocked" if recommendation == "ESCALATE" else "idle",
                          f"round {rnd}: {recommendation}")

    if args.record:
        entry = {"round": rnd, "verdict": args.record.upper(), "reason": args.reason,
                 "recommendation": recommendation,
                 "fabrications": bool(osum.get("fabricated_kills")),
                 "disagreements": bool(disagreements), "at": now()}
        ctx.state.setdefault("history", []).append(entry)
        ctx.state["status"] = {"PASS": "passed", "REVISE": "open", "ESCALATE": "escalated"}.get(
            args.record.upper(), "open")
        ctx.save()
    print(json.dumps(judgment, indent=2))


def cmd_feedback(args):
    """Render the next round's brief-back from a round's evidence.

    A draft, not a substitute for judgement: an orchestrator that reads the
    round should edit this before sending it. It exists so an unattended loop
    still hands the implementer specifics instead of "try again".
    """
    ctx = ctx_for(args)
    rnd = args.round or ctx.state["round"] or 1
    jud = read_json(ctx.round_dir(rnd) / "judgment.json", default={})
    rev = read_json(ctx.round_dir(rnd, "reviewer") / "REVIEW.json", default={})
    ver = read_json(ctx.round_dir(rnd, "implementer") / "verify.orchestrator.json", default={})
    verdict = jud.get("recorded_verdict") or jud.get("recommendation") or "REVISE"

    out = [f"# Round {rnd}: {verdict}", ""]
    if verdict == "PASS":
        out.append("Nothing blocking. This feedback should not have been requested.")
        text = "\n".join(out) + "\n"
    else:
        summary = ver.get("summary", {})
        out += ["## What the replay found", ""]
        out.append(f"- {summary.get('killed', 0)} of {summary.get('total', 0)} of your mutants died on replay.")
        if summary.get("fabricated_kills"):
            out.append(f"- **Claims that did not reproduce: {summary['fabricated_kills']}.** "
                       f"These were reported KILLED and survive when replayed. Re-measure with "
                       f"`darwin mutant run`; never hand-write a `claimed` value.")
        for g in ver.get("guards", []):
            out.append(f"- `{g['code']}` ({g['severity']}): {g['detail'].splitlines()[0][:300]}")
        out.append("")

        survivors = [a for a in (rev.get("adversarial_mutants") or [])
                     if (a.get("observed") or {}).get("status") == "SURVIVED"]
        if survivors:
            out += ["## The reviewer's mutants that your tests do not catch", "",
                    "Each of these is a defect your suite cannot see. Reproduce one with:",
                    "",
                    f"```",
                    f"cd <your worktree>",
                    f"git apply {ctx.round_dir(rnd, 'reviewer') / 'mutants'}/<ID>.patch",
                    f"{ctx.cfg['test']['command']}      # passes - that is the problem",
                    f"git checkout -- .",
                    f"```", ""]
            for a in survivors:
                out.append(f"- **{a.get('id')}** - {a.get('intent')}")
                if a.get("significance"):
                    out.append(f"  - why it matters: {a['significance']}")
            out += ["", "Write the test that kills each one, then adopt the mutant into your own "
                        "set and show it dying.", ""]

        weak = [m for m in (rev.get("mutant_findings") or [])
                if m.get("quality") in ("weak", "trivial")]
        if weak:
            out += ["## Mutants the reviewer graded as proving little", ""]
            for m in weak:
                out.append(f"- **{m.get('id')}** ({m.get('quality')}): {m.get('note')}")
            out += ["", "A mutant that also breaks the happy path is killed by tests that existed "
                        "before your work. Replace these with surgical ones that only the behaviour "
                        "under test can catch.", ""]

        if rev.get("coverage_gaps"):
            out += ["## Behaviour with no mutant on it", ""] + \
                   [f"- {g}" for g in rev["coverage_gaps"]] + [""]
        if rev.get("test_quality_issues"):
            out += ["## Test quality", ""] + \
                   [f"- {t}" for t in rev["test_quality_issues"]] + [""]
        if rev.get("dishonesty_findings"):
            out += ["## Reported as dishonesty - answer these directly", ""] + \
                   [f"- [{f.get('kind')}] {f.get('evidence')}" for f in rev["dishonesty_findings"]] + \
                   ["", "If you disagree, say so with evidence; if you agree, fix it and say what "
                        "you changed. Do not ignore it.", ""]

        out += ["## This round", "",
                "Work in the same worktree - the history is the evidence. Add tests first, as "
                "before, then re-measure every mutant (old and new) and rebuild the report.",
                ""]
        text = "\n".join(out) + "\n"

    target = Path(args.out) if args.out else ctx.round_dir(rnd) / "feedback.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    if args.out or args.quiet:
        print(str(target))
    else:
        sys.stdout.write(text)


def cmd_escalate(args):
    ctx = ctx_for(args)
    rnd = args.round or ctx.state["round"] or 1
    body = [
        f"# darwin escalation - human review required",
        "",
        f"- run: `{ctx.run_id}`", f"- round: {rnd} of {ctx.cfg['max_rounds']}",
        f"- repo: `{ctx.repo}`", f"- raised: {now()}", "",
        "## Reason", "", args.reason or "(none given)", "",
        "## Where to look", "",
        f"- task: `{ctx.run_dir / 'TASK.md'}`",
        f"- rounds: `{ctx.run_dir / 'rounds'}`",
        f"- implementer worktree: `{ctx.state['roles'].get('implementer', {}).get('worktree', 'n/a')}`",
        f"- reviewer worktree: `{ctx.state['roles'].get('reviewer', {}).get('worktree', 'n/a')}`",
        "",
        "## Round history", "",
    ]
    for h in ctx.state.get("history", []):
        body.append(f"- r{h['round']}: **{h['verdict']}** (auto: {h.get('recommendation')}) - {h.get('reason', '')}")
    text = "\n".join(body) + "\n"
    path = ctx.run_dir / "ESCALATION.md"
    path.write_text(text, encoding="utf-8")
    ctx.state["status"] = "escalated"
    ctx.save()
    bus_send(ctx, "orchestrator", "human", "escalation", {"reason": args.reason, "file": str(path)}, rnd)
    if herdr_available():
        run(["herdr", "notification", "show", "darwin: human review required",
             "--body", (args.reason or "")[:200], "--sound", "request"], timeout=15)
    print(text)


# --------------------------------------------------------------------------
# lifecycle commands
# --------------------------------------------------------------------------

def cmd_init(args):
    repo = find_repo(Path(args.cwd or os.getcwd()).resolve())
    overrides = {
        ("test", "command"): args.test_cmd,
        ("test", "single_command"): args.test_single_cmd,
        ("max_rounds",): args.max_rounds,
        ("isolation",): args.isolation,
        ("bus",): args.bus,
        ("agents", "implementer", "provider"): args.impl_provider,
        ("agents", "implementer", "model"): args.impl_model,
        ("agents", "reviewer", "provider"): args.reviewer_provider,
        ("agents", "reviewer", "model"): args.reviewer_model,
        ("mutation", "min_mutants"): args.min_mutants,
    }
    cfg = load_config(repo, overrides)
    ensure_excluded(repo)

    task = args.task
    if args.task_file:
        task = Path(args.task_file).read_text(encoding="utf-8")
    if not task:
        die("provide --task TEXT or --task-file PATH")

    _, dirty = git(["status", "--porcelain"], cwd=repo, check=False)
    if dirty.strip():
        warn("the repository has uncommitted changes; agents branch from the base ref and will not see them")

    base_ref = args.base or "HEAD"
    _, base_commit = git(["rev-parse", base_ref], cwd=repo)
    run_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{slugify(task.splitlines()[0] if task.strip() else 'task')}"
    run_dir = repo / ".darwin" / "runs" / run_id
    (run_dir / "bus" / "inbox").mkdir(parents=True, exist_ok=True)
    (run_dir / "TASK.md").write_text(task.rstrip() + "\n", encoding="utf-8")

    state = {
        "run_id": run_id, "created_at": now(), "repo": str(repo),
        "base_ref": base_ref, "base_commit": base_commit.strip(),
        "round": 0, "status": "open", "roles": {}, "history": [],
        "config": cfg,
    }
    write_json(run_dir / "run.json", state)
    (repo / ".darwin" / "current").write_text(run_id + "\n", encoding="utf-8")

    if not cfg["test"]["command"]:
        warn("no test command detected - set test.command in darwin.config.json or pass --test-cmd")
    print(json.dumps({
        "run_id": run_id, "run_dir": str(run_dir), "base_commit": base_commit.strip(),
        "test_command": cfg["test"]["command"], "isolation": isolation_mode(cfg), "bus": bus_mode(cfg),
        "implementer": {k: cfg["agents"]["implementer"][k] for k in ("provider", "model")},
        "reviewer": {k: cfg["agents"]["reviewer"][k] for k in ("provider", "model")},
        "max_rounds": cfg["max_rounds"],
    }, indent=2))


def cmd_worktree(args):
    ctx = ctx_for(args)
    if args.action == "add":
        role = args.role
        if role in ctx.state["roles"] and Path(ctx.state["roles"][role]["worktree"]).exists():
            info = ctx.state["roles"][role]
            # a later round means the implementer has moved on; the reviewer must
            # look at the code it is reviewing, not at last round's snapshot
            if role == "reviewer" and "implementer" in ctx.state["roles"]:
                wt = Path(info["worktree"])
                clean, _ = tree_clean(wt)
                if not clean:
                    revert_tree(wt)
                target = ctx.state["roles"]["implementer"]["branch"]
                git(["reset", "--hard", target], cwd=wt, check=False)
                info = {**info, "synced_to": head_commit(wt)}
                ctx.state["roles"][role] = info
                ctx.save()
            print(json.dumps(info, indent=2))
            return
        if args.base:
            base = args.base
        elif role == "reviewer" and "implementer" in ctx.state["roles"]:
            base = ctx.state["roles"]["implementer"]["branch"]
        else:
            base = ctx.state["base_commit"]
        prefix = ctx.cfg["branch_prefix"]
        branch = f"{prefix}/{ctx.run_id}/{role}"
        if args.round:
            branch += f"-r{args.round}"
        path = ctx.repo / ctx.cfg["worktree_root"] / ctx.run_id / role
        info = worktree_add(ctx, role, base, branch, path)
        ctx.state["roles"][role] = info
        ctx.save()
        print(json.dumps(info, indent=2))
    elif args.action == "remove":
        worktree_remove(ctx, args.role, delete_branch=args.delete_branch)
        ctx.state["roles"].pop(args.role, None)
        ctx.save()
        print(f"removed worktree for {args.role}")
    else:
        print(json.dumps(ctx.state["roles"], indent=2))


def cmd_prompt(args):
    ctx = ctx_for(args)
    rnd = args.round or ctx.state["round"] or 1
    feedback = Path(args.feedback_file).read_text(encoding="utf-8") if args.feedback_file else (args.feedback or "")
    text = render_prompt(ctx, args.role, rnd, feedback)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(args.out)
    else:
        sys.stdout.write(text)


def cmd_spawn(args):
    ctx = ctx_for(args)
    rnd = args.round or ctx.state["round"] or 1
    ctx.state["round"] = rnd
    if args.role not in ctx.state["roles"]:
        die(f"no worktree for {args.role} - run `darwin worktree add --role {args.role}` first")
    provider = ctx.cfg["agents"][args.role].get("provider")
    if provider == "inline" and not ctx.cfg["agents"][args.role].get("cmd"):
        die(f"agents.{args.role}.provider is 'inline': render the brief with "
            f"`darwin prompt --role {args.role} --round {rnd}` and run it with your own subagent instead")
    feedback = Path(args.feedback_file).read_text(encoding="utf-8") if args.feedback_file else (args.feedback or "")
    prompt = render_prompt(ctx, args.role, rnd, feedback)
    bus_send(ctx, "orchestrator", args.role, "assignment",
             {"round": rnd, "prompt": str(ctx.round_dir(rnd, args.role) / "PROMPT.md")}, rnd)
    register_orchestrator(ctx, "working", f"spawning {args.role} for round {rnd}")
    result = spawn_agent(ctx, args.role, rnd, prompt)
    bus_send(ctx, args.role, "orchestrator", "agent_exit",
             {k: result[k] for k in ("exit_code", "duration_s", "log")}, rnd)
    ctx.save()
    print(json.dumps({k: result[k] for k in ("role", "round", "provider", "model",
                                             "spawn_mode", "exit_code", "duration_s", "log")}, indent=2))


def cmd_msg(args):
    ctx = ctx_for(args)
    if args.action == "send":
        body = args.body
        if body:
            try:
                body = json.loads(body)
            except (json.JSONDecodeError, TypeError):
                pass
        if args.body_file:
            raw = Path(args.body_file).read_text(encoding="utf-8")
            try:
                body = json.loads(raw)
            except json.JSONDecodeError:
                body = raw
        msg = bus_send(ctx, args.sender, args.to, args.type, body, args.round)
        print(json.dumps(msg, indent=2))
    elif args.action == "wait":
        msg = bus_wait(ctx, args.to, args.type, int(args.timeout), int(args.since or 0))
        if msg is None:
            print(json.dumps({"timeout": True, "waited_s": int(args.timeout)}, indent=2))
            sys.exit(1)
        print(json.dumps(msg, indent=2))
    else:
        print(json.dumps(bus_read(ctx, args.to, args.type, int(args.since or 0)), indent=2))


def cmd_status(args):
    ctx = ctx_for(args)
    last = {}
    rounds = sorted((ctx.run_dir / "rounds").glob("r*")) if (ctx.run_dir / "rounds").exists() else []
    if rounds and (rounds[-1] / "judgment.json").exists():
        last = read_json(rounds[-1] / "judgment.json")
    print(json.dumps({
        "run_id": ctx.run_id, "status": ctx.state["status"], "round": ctx.state["round"],
        "max_rounds": ctx.cfg["max_rounds"], "run_dir": str(ctx.run_dir),
        "roles": ctx.state["roles"], "history": ctx.state.get("history", []),
        "last_judgment": {k: last.get(k) for k in ("round", "recommendation", "blocking", "escalate_reasons")},
    }, indent=2))


def cmd_land(args):
    ctx = ctx_for(args)
    impl = ctx.state["roles"].get("implementer")
    if not impl:
        die("no implementer worktree in this run")
    if ctx.state["status"] != "passed" and not args.force:
        die(f"run status is '{ctx.state['status']}', not 'passed' (use --force to override)")
    wt = Path(impl["worktree"])
    if args.strategy == "patch":
        _, diff = git(["diff", f"{ctx.state['base_commit']}..HEAD"], cwd=wt)
        out = ctx.run_dir / "RESULT.patch"
        out.write_text(diff, encoding="utf-8")
        print(json.dumps({"patch": str(out), "branch": impl["branch"],
                          "apply_with": f"git apply {out}"}, indent=2))
    else:
        if not args.yes:
            die("merging into the current checkout changes your working branch - pass --yes to confirm")
        clean, dirty = tree_clean(ctx.repo)
        if not clean:
            die(f"repository working tree is dirty, refusing to merge:\n{dirty}")
        code, out = git(["merge", "--no-ff", impl["branch"], "-m",
                         f"darwin: land {ctx.run_id} (mutation-verified)"], cwd=ctx.repo, check=False)
        print(out)
        sys.exit(code)


def cmd_clean(args):
    ctx = ctx_for(args)
    for role in list(ctx.state["roles"].keys()):
        worktree_remove(ctx, role, delete_branch=args.delete_branches)
        ctx.state["roles"].pop(role, None)
    for ws in ctx.state.pop("herdr_aux_workspaces", []):
        herdr_json(["workspace", "close", ws], timeout=60)
    ctx.save()
    if args.purge:
        shutil.rmtree(ctx.run_dir, ignore_errors=True)
        print(f"purged {ctx.run_dir}")
    else:
        print(f"worktrees removed; artefacts kept in {ctx.run_dir}")


def cmd_doctor(args):
    ctx = ctx_for(args, need_run=False)
    cfg = ctx.cfg
    providers = {}
    for role in ("implementer", "reviewer"):
        spec = cfg["agents"][role]
        if spec.get("cmd"):
            binary = (spec["cmd"] if isinstance(spec["cmd"], list) else shlex.split(spec["cmd"]))[0]
        else:
            binary = PROVIDERS.get(spec.get("provider"), {}).get("bin", "?")
        providers[role] = {"provider": spec.get("provider"), "model": spec.get("model"),
                           "binary": binary, "on_path": have(binary)}
    _, dirty = git(["status", "--porcelain"], cwd=ctx.repo, check=False)
    report = {
        "repo": str(ctx.repo), "clean_worktree": not dirty.strip(),
        "config_file": cfg.get("_config_file", "(defaults only)"),
        "git": run(["git", "--version"])[1].strip(),
        "herdr": {"installed": have("herdr"), "server_up": herdr_available()},
        "isolation": isolation_mode(cfg), "bus": bus_mode(cfg),
        "test_command": cfg["test"]["command"],
        "test_single_command": cfg["test"]["single_command"],
        "agents": providers,
        "min_mutants": cfg["mutation"]["min_mutants"], "max_rounds": cfg["max_rounds"],
    }
    problems = []
    if not report["test_command"]:
        problems.append("no test command configured or detected")
    for role, p in providers.items():
        if not p["on_path"] and p["provider"] != "inline":
            problems.append(f"{role}: CLI '{p['binary']}' not on PATH")
    if not report["test_single_command"]:
        problems.append("test.single_command unset - targeted 'this test kills this mutant' checks are disabled")
    report["problems"] = problems
    print(json.dumps(report, indent=2))
    sys.exit(1 if any("not on PATH" in p or "no test command" in p for p in problems) else 0)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="darwin", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cwd", help="run as if started in this directory")
    sub = p.add_subparsers(dest="command", required=True)

    def with_run(sp):
        sp.add_argument("--run", help="run id (defaults to .darwin/current)")
        return sp

    i = sub.add_parser("init", help="start a run: record the task, config and base commit")
    i.add_argument("--task"); i.add_argument("--task-file")
    i.add_argument("--base", help="base ref for agent worktrees (default HEAD)")
    i.add_argument("--test-cmd"); i.add_argument("--test-single-cmd")
    i.add_argument("--max-rounds", type=int)
    i.add_argument("--min-mutants", type=int)
    i.add_argument("--isolation", choices=["auto", "herdr", "git", "none"])
    i.add_argument("--bus", choices=["auto", "herdr", "file"])
    i.add_argument("--impl-provider"); i.add_argument("--impl-model")
    i.add_argument("--reviewer-provider"); i.add_argument("--reviewer-model")
    i.set_defaults(func=cmd_init)

    d = sub.add_parser("doctor", help="check git, herdr, provider CLIs and test-command detection")
    d.set_defaults(func=cmd_doctor)

    s = with_run(sub.add_parser("status", help="show run state, roles and last judgment"))
    s.set_defaults(func=cmd_status)

    w = with_run(sub.add_parser("worktree", help="create/remove the isolated worktree of a role"))
    w.add_argument("action", choices=["add", "remove", "list"])
    w.add_argument("--role", choices=["implementer", "reviewer"])
    w.add_argument("--base"); w.add_argument("--round", type=int)
    w.add_argument("--delete-branch", action="store_true")
    w.set_defaults(func=cmd_worktree)

    pr = with_run(sub.add_parser("prompt", help="render a role brief (use when you drive the agent yourself)"))
    pr.add_argument("--role", required=True, choices=["implementer", "reviewer"])
    pr.add_argument("--round", type=int); pr.add_argument("--feedback"); pr.add_argument("--feedback-file")
    pr.add_argument("--out"); pr.set_defaults(func=cmd_prompt)

    sp = with_run(sub.add_parser("spawn", help="render the brief and launch the role's agent CLI"))
    sp.add_argument("--role", required=True, choices=["implementer", "reviewer"])
    sp.add_argument("--round", type=int); sp.add_argument("--feedback"); sp.add_argument("--feedback-file")
    sp.set_defaults(func=cmd_spawn)

    m = with_run(sub.add_parser("msg", help="file-backed message bus between orchestrator and agents"))
    m.add_argument("action", choices=["send", "wait", "list"])
    m.add_argument("--from", dest="sender", default="orchestrator")
    m.add_argument("--to"); m.add_argument("--type"); m.add_argument("--body")
    m.add_argument("--body-file"); m.add_argument("--round", type=int)
    m.add_argument("--since", type=int, default=0); m.add_argument("--timeout", type=int, default=600)
    m.set_defaults(func=cmd_msg)

    mu = (sub.add_parser("mutant", help="capture and measure mutants inside a role worktree"))
    mus = mu.add_subparsers(dest="mutant_action", required=True)
    mc = mus.add_parser("capture", help="snapshot the current working-tree edit as a mutant patch, then revert")
    mc.add_argument("--run"); mc.add_argument("--role", required=True)
    mc.add_argument("--round", type=int); mc.add_argument("--id", required=True)
    mc.add_argument("--operator", required=True, help="mutation operator, see references/mutation-catalog.md")
    mc.add_argument("--intent", required=True, help="the real defect this mutant simulates")
    mc.add_argument("--symbol", help="function/method mutated")
    mc.add_argument("--expected-killers", help="comma-separated test selectors that must fail")
    mc.add_argument("--keep", action="store_true", help="do not revert the edit after capturing")
    mc.set_defaults(func=cmd_mutant_capture)
    mr = mus.add_parser("run", help="apply mutant(s), run the suite, revert, record the result")
    mr.add_argument("--run"); mr.add_argument("--role", required=True)
    mr.add_argument("--round", type=int); mr.add_argument("--id", help="single mutant id (default: all)")
    mr.set_defaults(func=cmd_mutant_run)

    rb = (sub.add_parser("report", help="build the measured MUTATION-REPORT.json skeleton"))
    rbs = rb.add_subparsers(dest="report_action", required=True)
    rbb = rbs.add_parser("build")
    rbb.add_argument("--run"); rbb.add_argument("--role", required=True)
    rbb.add_argument("--round", type=int)
    rbb.add_argument("--baseline", action="store_true", help="also run the unmutated suite")
    rbb.add_argument("--force", action="store_true")
    rbb.set_defaults(func=cmd_report_build)

    v = with_run(sub.add_parser("verify", help="independently replay every mutant and diff against the claims"))
    v.add_argument("--role", required=True, choices=["implementer", "reviewer"],
                   help="whose worktree to replay in")
    v.add_argument("--round", type=int)
    v.add_argument("--report", help="report to verify (default: this role's MUTATION-REPORT.json)")
    v.add_argument("--verifier", default="orchestrator", help="label for the output file")
    v.add_argument("--out"); v.set_defaults(func=cmd_verify)

    j = with_run(sub.add_parser("judge", help="combine report + verifications + review into a verdict"))
    j.add_argument("--round", type=int)
    j.add_argument("--record", choices=["PASS", "REVISE", "ESCALATE", "pass", "revise", "escalate"],
                   help="record the orchestrator's final verdict for this round")
    j.add_argument("--reason"); j.set_defaults(func=cmd_judge)

    wv = with_run(sub.add_parser("watch", help="live status board for a run"))
    wv.add_argument("--once", action="store_true", help="print one frame and exit")
    wv.add_argument("--follow", action="store_true", help="keep refreshing after the run ends")
    wv.add_argument("--interval", type=int, default=3)
    wv.set_defaults(func=cmd_watch)

    ui = with_run(sub.add_parser("ui", help="open a herdr workspace that renders the run"))
    ui.add_argument("--once", action="store_true"); ui.add_argument("--follow", action="store_true")
    ui.add_argument("--interval", type=int, default=3)
    ui.set_defaults(func=cmd_ui)

    fb = with_run(sub.add_parser("feedback", help="draft the next round's brief-back from this round's evidence"))
    fb.add_argument("--round", type=int); fb.add_argument("--out")
    fb.add_argument("--quiet", action="store_true", help="print the path, not the text")
    fb.set_defaults(func=cmd_feedback)

    e = with_run(sub.add_parser("escalate", help="stop the loop and write a human-review request"))
    e.add_argument("--round", type=int); e.add_argument("--reason", required=True)
    e.set_defaults(func=cmd_escalate)

    l = with_run(sub.add_parser("land", help="export or merge the accepted implementer branch"))
    l.add_argument("--strategy", choices=["patch", "merge"], default="patch")
    l.add_argument("--yes", action="store_true"); l.add_argument("--force", action="store_true")
    l.set_defaults(func=cmd_land)

    c = with_run(sub.add_parser("clean", help="remove this run's worktrees (artefacts are kept)"))
    c.add_argument("--delete-branches", action="store_true")
    c.add_argument("--purge", action="store_true", help="also delete the run directory and its evidence")
    c.set_defaults(func=cmd_clean)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if getattr(args, "command", None) == "worktree" and args.action in ("add", "remove") and not args.role:
        die("--role is required for `worktree add|remove`")
    if getattr(args, "command", None) == "msg" and args.action in ("send", "wait") and not args.to:
        die("--to is required for `msg send|wait`")
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
