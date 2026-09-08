#!/usr/bin/env python3
"""Status and federation endpoint on 0.0.0.0:8080.

The Clever Cloud linux runtime only considers an instance healthy once
something answers on port 8080, and 8080 is also the *only* port the
platform exposes - arbitrary ports are not routed between instances, on
either the public or the private address. So this doubles as the fleet's
inter-VM channel: every box is reachable from every other at
https://app-<id>.cleverapps.io over TLS, with no SSH key on the Clever
account and no port arithmetic.

Everything except `/` requires the fleet token, because that URL is
public to the internet.
"""
import json
import os
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/vm-agent-state")
BOOT_LOG = os.environ.get("BOOT_LOG", "/tmp/vm-agent-boot.log")
VM_NAME = os.environ.get("VM_AGENT_NAME", "vm-agent")
FLEET_TOKEN = os.environ.get("VM_AGENT_FLEET_TOKEN", "")
TOOLS = ["herdr", "claude", "opencode", "codex", "gh", "glab", "git", "s3cmd",
         "moerae", "fleet", "cellar"]
MAX_BODY = 64 * 1024
MAX_OUT = 8 * 1024 * 1024
OUT_DIR = os.path.expanduser("~/out")

HOME = os.path.expanduser("~")
SEARCH_PATH = os.pathsep.join([
    os.path.join(HOME, ".local/bin"),
    os.path.join(HOME, ".opencode/bin"),
    os.environ.get("PATH", ""),
])


def which(tool):
    return shutil.which(tool, path=SEARCH_PATH)


def herdr(*args, timeout=30):
    """Run a herdr subcommand and return its JSON, never through a shell."""
    exe = which("herdr")
    if not exe:
        return 503, {"error": "herdr is not installed on this VM"}
    try:
        proc = subprocess.run([exe, *args], capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return 504, {"error": "herdr timed out", "argv": list(args)}
    out = (proc.stdout or "").strip()
    try:
        return (200 if proc.returncode == 0 else 500), json.loads(out)
    except (ValueError, TypeError):
        return (200 if proc.returncode == 0 else 500), {
            "output": out,
            "stderr": (proc.stderr or "").strip(),
            "exit": proc.returncode,
        }


# ------------------------------------------------------------- herdr shim
# herdr's own API is a unix socket, mode 0600, local to the VM - it has no
# network listener at all, and the platform's ssh gateway refuses port
# forwarding, so the socket cannot be reached from off the box. This shim
# is the only way in, and hand-writing a route per verb meant every new
# herdr subcommand needed a redeploy to become usable. So pass argv
# through instead, and police it by namespace.
#
# What this is NOT is a security boundary. Anyone holding the fleet token
# can already POST /agents/<name>/prompt to an agent running with
# bypassPermissions, which is arbitrary code execution on this VM. The
# rules below exist to stop *accidents* - a request that never returns, or
# that takes the whole session down with it - not to contain an attacker.
HERDR_NAMESPACES = {
    "agent", "pane", "tab", "workspace", "worktree", "notification",
    "api", "session",
}
# Excluded on purpose, because they change the box rather than the session:
# server (stop/reload-config), config (reset-keys), channel (set), and
# integration (install/uninstall).

# Interactive: hands over a terminal and never returns, so it would hold a
# request open until the timeout and give nothing back.
HERDR_DENY_VERBS = {"attach"}

# The session owns every workspace, pane and agent on the VM. Stopping or
# deleting it is not a management operation, it is a teardown.
HERDR_DENY_PAIRS = {("session", "stop"), ("session", "delete")}

HERDR_MAX_ARGV = 24
HERDR_MAX_ARG = 4096
HERDR_MAX_TIMEOUT = 120


def herdr_allowed(argv):
    """(ok, reason) for a proposed herdr argv."""
    if not argv or not all(isinstance(a, str) and a for a in argv):
        return False, "argv must be a non-empty list of non-empty strings"
    if len(argv) > HERDR_MAX_ARGV:
        return False, f"argv is longer than {HERDR_MAX_ARGV}"
    if any(len(a) > HERDR_MAX_ARG for a in argv):
        return False, f"an argument is longer than {HERDR_MAX_ARG} bytes"
    ns = argv[0]
    if ns not in HERDR_NAMESPACES:
        return False, (f"'{ns}' is not a permitted namespace; "
                       f"allowed: {' '.join(sorted(HERDR_NAMESPACES))}")
    verb = argv[1] if len(argv) > 1 else ""
    if verb in HERDR_DENY_VERBS:
        return False, f"'{ns} {verb}' is interactive and would never return"
    if (ns, verb) in HERDR_DENY_PAIRS:
        return False, f"'{ns} {verb}' would tear down the whole session"
    return True, ""


AGENT_KINDS = {
    "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline",
    "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid",
    "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "maki",
}


def start_agent(name, kind, cwd, label):
    """Create a pane and launch an agent in it.

    A headless server starts with no workspace at all, so the first agent
    has to create one; later ones get a tab in the existing workspace.
    Both calls return the new pane under .result.root_pane.
    """
    code, listing = herdr("workspace", "list")
    if code != 200:
        return code, listing
    workspaces = (listing.get("result") or {}).get("workspaces") or []

    if workspaces:
        code, made = herdr("tab", "create", "--workspace",
                           workspaces[0]["workspace_id"], "--cwd", cwd,
                           "--label", label)
    else:
        code, made = herdr("workspace", "create", "--cwd", cwd, "--label", label)
    if code != 200:
        return code, made

    pane = ((made.get("result") or {}).get("root_pane") or {}).get("pane_id")
    if not pane:
        return 500, {"error": "could not determine the new pane", "response": made}

    # `agent start` reports agent_not_ready if the CLI is still drawing its
    # welcome screen when the readiness check fires - that is not a failure,
    # so settle for whatever state the agent has actually reached.
    start_code, started = herdr("agent", "start", name, "--kind", kind,
                                "--pane", pane, "--timeout", "60000",
                                timeout=120)
    _, got = herdr("agent", "get", name)
    agent = (got.get("result") or {}).get("agent") or {}

    if not agent.get("interactive_ready"):
        accept_bypass_warning(name)
        _, got = herdr("agent", "get", name)
        agent = (got.get("result") or {}).get("agent") or {}
    if agent.get("interactive_ready"):
        return 200, {"started": True, "pane": pane, "agent": agent}
    return 202, {"started": False, "pane": pane, "agent": agent,
                 "start_response": started, "start_code": start_code,
                 "hint": "agent is not interactive yet; poll GET /agents/<name>"}


def accept_bypass_warning(name):
    """Clear Claude Code's one-time bypass-permissions warning.

    Turning bypassPermissions on introduces its own confirmation, which
    would wedge the first agent on every brand-new VM. Answering it here is
    not overriding a safety decision - the operator made that decision by
    setting CLAUDE_PERMISSION_MODE. Deliberately narrow: it fires only when
    that exact screen is on the pane.
    """
    if os.environ.get("CLAUDE_PERMISSION_MODE") != "bypassPermissions":
        return False
    code, out = herdr("agent", "read", name, "--source", "visible")
    if code != 200:
        return False
    text = json.dumps(out)
    if "Bypass Permissions mode" not in text or "Yes, I accept" not in text:
        return False
    # An arrow-key menu defaulting to "No, exit", with no numeric shortcuts
    # on Claude Code 2.x - so the "2" this used to send did nothing, and the
    # first agent on every freshly provisioned VM sat on this screen for
    # ever. It never showed on an existing box: ~/.claude.json already
    # records the acceptance and is restored from the bucket, so only a
    # brand-new fleet could reveal it. Older builds did number the options,
    # so "2" is kept as a fallback.
    #
    # Confirm the screen actually cleared rather than assuming the keys
    # landed - assuming is what made the previous version fail silently.
    for keys in (("down", "enter"), ("2",)):
        herdr("agent", "send-keys", name, *keys)
        time.sleep(3)
        code, out = herdr("agent", "read", name, "--source", "visible")
        if code == 200 and "Bypass Permissions mode" not in json.dumps(out):
            return True
    return False


def read_stage():
    try:
        with open(STATE_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return "starting"


def agent_auth():
    """Which agents have credentials, without ever revealing them."""
    if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        claude = "subscription-token"
    elif os.environ.get("ANTHROPIC_API_KEY"):
        claude = "api-key"
    elif os.path.exists(os.path.join(HOME, ".claude/.credentials.json")):
        claude = "session"
    else:
        claude = None

    if os.path.exists(os.path.join(HOME, ".codex/auth.json")):
        codex = "logged-in"
    elif os.environ.get("OPENAI_API_KEY"):
        codex = "api-key"
    else:
        codex = None

    providers = [name for name, var in (
        ("anthropic", "ANTHROPIC_API_KEY"),
        ("openai", "OPENAI_API_KEY"),
        ("openrouter", "OPENROUTER_API_KEY"),
    ) if os.environ.get(var)]
    if not providers and os.path.exists(
            os.path.join(HOME, ".local/share/opencode/auth.json")):
        providers = ["stored-credentials"]

    return {"claude": claude, "codex": codex, "opencode": providers or None}


def status_payload():
    return {
        "vm": VM_NAME,
        "app": os.environ.get("CC_APP_NAME", "vm-agent"),
        "instance": os.environ.get("CC_PRETTY_INSTANCE_NAME"),
        "deployment": os.environ.get("CC_DEPLOYMENT_ID"),
        "stage": read_stage(),
        "ready": read_stage() == "ready",
        "persistent_storage": os.path.ismount(os.environ.get(
            "PERSIST_ROOT", os.path.join(os.environ.get("APP_HOME", "~"),
                                         "persistent"))),
        "tools": {tool: which(tool) for tool in TOOLS},
        "agent_auth": agent_auth(),
        "federation": bool(FLEET_TOKEN),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vm-agent"

    # -- plumbing ------------------------------------------------------
    def _send(self, code, body, ctype="application/json"):
        raw = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, indent=2) + "\n")

    def _authorised(self):
        # Fail closed: with no token configured nothing but / is reachable,
        # so a half-provisioned box never exposes its logs to the internet.
        if not FLEET_TOKEN:
            self._json(503, {"error": "federation token not configured"})
            return False
        header = self.headers.get("Authorization", "")
        presented = header[7:] if header.startswith("Bearer ") else ""
        if not presented:
            presented = self.headers.get("X-Fleet-Token", "")
        # Constant-time-ish: compare full strings, not prefixes.
        if presented != FLEET_TOKEN:
            self._json(401, {"error": "unauthorised"})
            return False
        return True

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length).decode())
        except (ValueError, UnicodeDecodeError):
            return None

    # -- routes --------------------------------------------------------
    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)

        # Unauthenticated: the platform's own health probe.
        if not parts:
            return self._json(200, {"ok": True, "vm": VM_NAME,
                                    "ready": read_stage() == "ready"})

        if not self._authorised():
            return

        if parts == ["status"]:
            return self._json(200, status_payload())

        if parts == ["logs"]:
            try:
                with open(BOOT_LOG) as fh:
                    return self._send(200, fh.read(), "text/plain; charset=utf-8")
            except OSError:
                return self._json(404, {"error": "no boot log yet"})

        if parts == ["out"]:
            try:
                names = sorted(n for n in os.listdir(OUT_DIR)
                               if os.path.isfile(os.path.join(OUT_DIR, n)))
            except OSError:
                names = []
            return self._json(200, {"vm": VM_NAME, "files": [
                {"name": n, "bytes": os.path.getsize(os.path.join(OUT_DIR, n))}
                for n in names]})

        if len(parts) == 2 and parts[0] == "out":
            # Basename only: no traversal out of the drop directory.
            name = os.path.basename(parts[1])
            if not name or name.startswith("."):
                return self._json(400, {"error": "bad file name"})
            path = os.path.join(OUT_DIR, name)
            if not os.path.isfile(path):
                return self._json(404, {"error": f"no such output: {name}"})
            if os.path.getsize(path) > MAX_OUT:
                return self._json(413, {"error": "output too large",
                                        "bytes": os.path.getsize(path)})
            with open(path, "rb") as fh:
                return self._send(200, fh.read(), "text/plain; charset=utf-8")

        if parts == ["herdr"]:
            code, server = herdr("status", "server")
            return self._json(200, {
                "call": "POST /herdr with {\"argv\": [...], \"timeout\": seconds}",
                "namespaces": sorted(HERDR_NAMESPACES),
                "denied_verbs": sorted(HERDR_DENY_VERBS),
                "denied": [" ".join(p) for p in sorted(HERDR_DENY_PAIRS)],
                "max_argv": HERDR_MAX_ARGV,
                "max_timeout": HERDR_MAX_TIMEOUT,
                "server": server if code == 200 else {"error": server},
            })

        if parts == ["agents"]:
            return self._json(*herdr("agent", "list"))

        if parts == ["panes"]:
            return self._json(*herdr("pane", "list"))

        if len(parts) == 2 and parts[0] == "agents":
            return self._json(*herdr("agent", "get", parts[1]))

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "read":
            source = (query.get("source") or ["recent"])[0]
            if source not in ("visible", "recent", "recent-unwrapped", "detection"):
                return self._json(400, {"error": f"bad source: {source}"})
            return self._json(*herdr("agent", "read", parts[1], "--source", source))

        self._json(404, {"error": "not found", "path": url.path})

    def do_POST(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not self._authorised():
            return

        body = self._body()
        if body is None or not isinstance(body, dict):
            return self._json(400, {"error": "expected a JSON object body"})

        if parts == ["agents"]:
            name = body.get("name")
            kind = body.get("kind", "claude")
            if not isinstance(name, str) or not name.replace("-", "").replace("_", "").isalnum():
                return self._json(400, {"error": "'name' must be alphanumeric (- and _ allowed)"})
            if kind not in AGENT_KINDS:
                return self._json(400, {"error": f"unsupported kind: {kind}",
                                        "supported": sorted(AGENT_KINDS)})
            cwd = body.get("cwd") or os.path.join(HOME, "workspace")
            if not isinstance(cwd, str) or not os.path.isdir(cwd):
                return self._json(400, {"error": f"cwd is not a directory: {cwd}"})
            label = body.get("label") or name
            if not isinstance(label, str):
                return self._json(400, {"error": "'label' must be a string"})
            return self._json(*start_agent(name, kind, cwd, label))

        if parts == ["herdr"]:
            argv = body.get("argv")
            if not isinstance(argv, list):
                return self._json(400, {"error": "'argv' must be a list of strings"})
            ok, why = herdr_allowed(argv)
            if not ok:
                return self._json(400, {"error": why, "argv": argv})
            timeout = body.get("timeout", 30)
            if not isinstance(timeout, (int, float)) or not 1 <= timeout <= HERDR_MAX_TIMEOUT:
                return self._json(400, {
                    "error": f"'timeout' must be a number of seconds, 1..{HERDR_MAX_TIMEOUT}"})
            return self._json(*herdr(*argv, timeout=timeout))

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "prompt":
            text = body.get("text")
            if not isinstance(text, str) or not text:
                return self._json(400, {"error": "'text' must be a non-empty string"})
            return self._json(*herdr("agent", "prompt", parts[1], text, timeout=60))

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "keys":
            keys = body.get("keys")
            if not isinstance(keys, list) or not keys or \
                    not all(isinstance(k, str) and k for k in keys):
                return self._json(400, {"error": "'keys' must be a non-empty list of strings"})
            return self._json(*herdr("agent", "send-keys", parts[1], *keys))

        self._json(404, {"error": "not found", "path": self.path})

    def log_message(self, *args):  # keep the platform log readable
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
