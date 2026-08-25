#!/usr/bin/env bash
# Give the coding agents their credentials.
#
# Tokens arrive as environment variables from the shared Configuration
# provider, so a rotation is one write for the whole fleet. Two of the
# three agents need nothing more than the variable being present:
#
#   claude   reads CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY) directly
#   opencode reads ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY
#   codex    keeps credentials in a file, so it gets an explicit login
#
# ChatGPT-subscription login for codex cannot be a shared secret the way
# CLAUDE_CODE_OAUTH_TOKEN is: codex's OAuth refresh token rotates on every
# use, so a copy handed to a second machine (or reused after the source
# session has refreshed even once) dies with "refresh token was already
# used" on its very first real request - confirmed against a live VM, not
# theoretical. Run `codex login --device-auth` once per VM instead - it is
# already snapshotted by 00-persist.sh, so that session survives restarts
# exactly like an interactive `claude auth login` does for Claude.
#
# An interactive `claude auth login` / `codex login` inside a box still
# works and survives restarts through the state snapshot; this script only
# covers the zero-touch path.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

# Masked, so a token never reaches the platform log.
mask() { local v="$1"; [ -n "$v" ] && printf '%s…%s (%d chars)' "${v:0:6}" "${v: -4}" "${#v}" || printf 'unset'; }

# Claude Code keeps first-run state in ~/.claude.json, separate from the
# ~/.claude directory. Without it the TUI stops at the login selector even
# when CLAUDE_CODE_OAUTH_TOKEN is set and headless `claude -p` works fine -
# which is exactly what blocks an agent launched into a herdr pane.
seed_claude_onboarding() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] || return 0
  local version
  version="$(claude --version 2>/dev/null | awk '{print $1}')"
  CLAUDE_JSON="$HOME/.claude.json" CLAUDE_VERSION="$version" \
  CLAUDE_TRUST_DIRS="$HOME/workspace:$APP_HOME" python3 - <<'PYEOF'
import json, os

path = os.environ["CLAUDE_JSON"]
version = os.environ.get("CLAUDE_VERSION") or "0.0.0"
try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}

changed = []
if data.get("hasCompletedOnboarding") is not True:
    data["hasCompletedOnboarding"] = True
    data.setdefault("lastOnboardingVersion", version)
    changed.append("onboarding")

# The folder-trust prompt is the second thing that blocks a pane agent.
# Trusting the VM's own workspace is safe: it is the box's whole purpose,
# and only directories we provisioned are listed here.
projects = data.setdefault("projects", {})
if not isinstance(projects, dict):
    projects = data["projects"] = {}
for raw in os.environ.get("CLAUDE_TRUST_DIRS", "").split(":"):
    d = os.path.realpath(raw) if raw else ""
    if not d or not os.path.isdir(d):
        continue
    entry = projects.setdefault(d, {})
    if not isinstance(entry, dict):
        entry = projects[d] = {}
    if entry.get("hasTrustDialogAccepted") is not True:
        entry["hasTrustDialogAccepted"] = True
        entry.setdefault("hasCompletedProjectOnboarding", True)
        entry.setdefault("allowedTools", [])
        changed.append(f"trust:{d}")

if changed:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)
    print("claude: seeded " + ", ".join(changed))
else:
    print("claude: onboarding and folder trust already seeded")
PYEOF
}

# How much a pane agent may do without asking. An agent launched through
# the fleet endpoint has nobody at the keyboard, so a permission prompt
# just wedges it - `fleet keys <vm>/<agent> 1` is a workaround, not a
# workflow. Set CLAUDE_PERMISSION_MODE in fleet.conf:
#   default          ask for everything (interactive use)
#   acceptEdits      auto-approve file edits, still ask before commands
#   bypassPermissions run unattended - no prompts at all
seed_claude_permissions() {
  local mode="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
  case "$mode" in
    default|acceptEdits|bypassPermissions|plan) ;;
    *) log "claude: ignoring unknown CLAUDE_PERMISSION_MODE '$mode'"; return 0 ;;
  esac
  mkdir -p "$HOME/.claude"
  CLAUDE_SETTINGS="$HOME/.claude/settings.json" CLAUDE_MODE="$mode" python3 - <<'PYEOF'
import json, os

path = os.environ["CLAUDE_SETTINGS"]
mode = os.environ["CLAUDE_MODE"]
try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}

perms = data.setdefault("permissions", {})
if not isinstance(perms, dict):
    perms = data["permissions"] = {}

if perms.get("defaultMode") == mode:
    print(f"claude: permission mode already {mode}")
else:
    perms["defaultMode"] = mode
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)
    print(f"claude: permission mode set to {mode}")
PYEOF
}

claude_auth() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "claude: long-lived subscription token $(mask "$CLAUDE_CODE_OAUTH_TOKEN")"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "claude: ANTHROPIC_API_KEY $(mask "$ANTHROPIC_API_KEY")"
  elif [ -f "$HOME/.claude/.credentials.json" ]; then
    log "claude: using the session restored from persistent storage"
  else
    log "claude: no credentials - run 'claude auth login' inside the box, or set CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  # `claude auth status` exits non-zero when unauthenticated; report either way.
  claude auth status 2>&1 | sed 's/^/[claude] /' | head -5 || true
}

# codex's sandbox needs bubblewrap for real isolation, which does not
# exist on this no-root, no-package-manager runtime - codex falls back to
# a bundled copy, but the fallback is unnecessary work for a threat model
# this fleet already resolved differently: the VM itself is the isolation
# boundary (a disposable, single-purpose container), and
# CLAUDE_PERMISSION_MODE=bypassPermissions already means "no per-command
# gates" for Claude. danger-full-access + never is the same posture for
# codex, and it skips constructing a sandbox at all, which is what
# actually removes the bubblewrap warning - installing bubblewrap would
# not, since there is nowhere to install it to.
#
# Must land before any [projects."<dir>"] table seed_codex_trust below
# writes: TOML has no "back to top-level" marker, so a bare key placed
# after a table header would silently become a property of that table
# instead of a top-level setting. Insert into the preamble, not the end.
seed_codex_permissions() {
  local mode="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
  [ "$mode" = "bypassPermissions" ] || return 0
  have codex || return 0
  mkdir -p "$HOME/.codex"
  CODEX_CONFIG="$HOME/.codex/config.toml" python3 - <<'PYEOF'
import os, re

path = os.environ["CODEX_CONFIG"]
try:
    with open(path) as fh:
        text = fh.read()
except OSError:
    text = ""

wanted = [
    ("sandbox_mode", 'sandbox_mode = "danger-full-access"'),
    ("approval_policy", 'approval_policy = "never"'),
]
new_lines = [line for key, line in wanted if not re.search(r'(?m)^' + re.escape(key) + r'\s*=', text)]

if new_lines:
    # Split at the first table header - everything before it is top-level
    # preamble, where a bare key belongs; everything from it on must be
    # left exactly as it is.
    m = re.search(r'(?m)^\[', text)
    cut = m.start() if m else len(text)
    preamble, rest = text[:cut], text[cut:]
    if preamble and not preamble.endswith("\n"):
        preamble += "\n"
    preamble += "\n".join(new_lines) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(preamble + rest)
    os.replace(tmp, path)
    print("codex: unattended mode (danger-full-access, never) - " + ", ".join(k for k, _ in wanted))
else:
    print("codex: unattended mode already seeded")
PYEOF
}

# codex's own folder-trust prompt - the same gate Claude's onboarding
# seeding above answers, just a different agent asking it. Unattended, it
# wedges the pane forever: found live, on a fresh box, via herdr - a
# `codex` pane sat at "Do you trust the contents of this directory?"
# with no agent identity yet for `herdr agent send-keys` to reach, so
# there was no way to answer it after the fact.
seed_codex_trust() {
  have codex || return 0
  mkdir -p "$HOME/.codex"
  CODEX_CONFIG="$HOME/.codex/config.toml" CODEX_TRUST_DIRS="$HOME/workspace:$APP_HOME" python3 - <<'PYEOF'
import os

path = os.environ["CODEX_CONFIG"]
try:
    with open(path) as fh:
        text = fh.read()
except OSError:
    text = ""

added = []
for raw in os.environ.get("CODEX_TRUST_DIRS", "").split(":"):
    d = os.path.realpath(raw) if raw else ""
    if not d or not os.path.isdir(d):
        continue
    header = '[projects."{}"]'.format(d)
    if header in text:
        continue  # already seeded, or a deliberate manual setting - leave it
    text += "\n{}\ntrust_level = \"trusted\"\n".format(header)
    added.append(d)

if added:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)
    print("codex: trusted " + ", ".join(added))
else:
    print("codex: folder trust already seeded")
PYEOF
}

codex_auth() {
  have codex || return 0
  if codex login status >/dev/null 2>&1; then
    log "codex: already logged in"
    return 0
  fi
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    if printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null 2>&1; then
      log "codex: logged in with OPENAI_API_KEY $(mask "$OPENAI_API_KEY")"
    else
      log "codex: OPENAI_API_KEY was rejected"
    fi
  else
    log "codex: no credentials - run 'codex login --device-auth' inside the box" \
        "for a ChatGPT subscription, or set OPENAI_API_KEY for pay-as-you-go"
  fi
}

opencode_auth() {
  have opencode || return 0
  local found=()
  [ -n "${ANTHROPIC_API_KEY:-}" ]  && found+=(anthropic)
  [ -n "${OPENAI_API_KEY:-}" ]     && found+=(openai)
  [ -n "${OPENROUTER_API_KEY:-}" ] && found+=(openrouter)
  if [ "${#found[@]}" -gt 0 ]; then
    log "opencode: provider keys in environment: ${found[*]}"
  elif [ -f "$HOME/.local/share/opencode/auth.json" ]; then
    log "opencode: using the credentials restored from persistent storage"
  else
    log "opencode: no provider keys - run 'opencode auth login' inside the box"
  fi
}

seed_claude_onboarding 2>&1 | sed 's/^/[vm-agent] /' || true
seed_claude_permissions 2>&1 | sed 's/^/[vm-agent] /' || true
seed_codex_permissions 2>&1 | sed 's/^/[vm-agent] /' || true
seed_codex_trust 2>&1 | sed 's/^/[vm-agent] /' || true
claude_auth   || true
codex_auth    || true
opencode_auth || true
