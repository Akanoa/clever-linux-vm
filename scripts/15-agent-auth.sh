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
# An interactive `claude auth login` / `codex login` inside a box still
# works and survives restarts through the state snapshot; this script only
# covers the zero-touch path.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

# Masked, so a token never reaches the platform log.
mask() { local v="$1"; [ -n "$v" ] && printf '%s…%s (%d chars)' "${v:0:6}" "${v: -4}" "${#v}" || printf 'unset'; }

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
    log "codex: no credentials - run 'codex login' inside the box, or set OPENAI_API_KEY"
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

claude_auth   || true
codex_auth    || true
opencode_auth || true
