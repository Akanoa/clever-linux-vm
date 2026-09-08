#!/usr/bin/env bash
# Capture agent and forge tokens into .secrets/tokens.env (gitignored).
#
# Nothing here talks to Clever Cloud: it only fills the local secrets file
# that provision.sh reads. Apply the result with:
#
#     ./provision.sh --all --no-deploy
#
#   ./agent-tokens.sh                 show what is set (masked)
#   ./agent-tokens.sh claude          run `claude setup-token` and store it
#   ./agent-tokens.sh set  <VAR>      prompt for a value without echoing it
#   ./agent-tokens.sh unset <VAR>     remove it
#
# `set` reads the value from stdin when it is not a terminal, so a token
# already on disk goes straight in without ever being echoed:
#
#     sed -n '...' ~/.cargo/credentials.toml \
#       | ./agent-tokens.sh set CARGO_REGISTRIES_KELLNR_TOKEN
#
# Besides the fixed list below, any CARGO_REGISTRIES_<NAME>_TOKEN is
# accepted, so a private cargo registry works without editing this script.
# The registry's index URL is not a secret and belongs in the project's own
# .cargo/config.toml; only the token travels through here.
#
# codex has no equivalent: a ChatGPT-subscription login's OAuth refresh
# token rotates on every use, so sharing one captured file breaks it on
# the very first real request elsewhere. Run `codex login --device-auth`
# on each VM directly instead - see the README.
set -uo pipefail

print_header_comment() {
  # The full leading comment block - not a fixed line range, which silently
  # truncates the help as soon as anyone adds a line to it.
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$ROOT/.secrets"
TOKENS="$SECRETS_DIR/tokens.env"

KNOWN=(
  "CLAUDE_CODE_OAUTH_TOKEN:Claude Code, long-lived subscription token"
  "ANTHROPIC_API_KEY:Anthropic API key (claude + opencode)"
  "OPENAI_API_KEY:OpenAI API key (codex + opencode)"
  "OPENROUTER_API_KEY:OpenRouter key (opencode)"
  "GH_TOKEN:GitHub CLI and HTTPS pushes"
  "GITLAB_TOKEN:GitLab CLI"
)

c_ok=$'\033[32m'; c_dim=$'\033[2m'; c_err=$'\033[31m'; c_off=$'\033[0m'
ok()  { printf '%s%s%s\n' "$c_ok"  "  ✓ $*" "$c_off"; }
dim() { printf '%s%s%s\n' "$c_dim" "  · $*" "$c_off"; }
die() { printf '%s%s%s\n' "$c_err" "  ✗ $*" "$c_off" >&2; exit 1; }

init_store() {
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  [ -f "$TOKENS" ] && return
  {
    echo '# Sourced by provision.sh. Gitignored - never commit this file.'
    echo '# An empty value keeps whatever is already in the config provider.'
  } > "$TOKENS"
  chmod 600 "$TOKENS"
}

# The allowlist is here to catch typos, not to be exhaustive: a name that
# follows cargo's own CARGO_REGISTRIES_<NAME>_TOKEN spelling is just as
# unambiguous as a fixed entry, and the registry name cannot be enumerated
# in advance.
DYNAMIC_RE='^CARGO_REGISTRIES_[A-Z0-9_]+_TOKEN$'

is_known() {
  local var
  for entry in "${KNOWN[@]}"; do var="${entry%%:*}"; [ "$var" = "$1" ] && return 0; done
  printf '%s' "$1" | grep -qE "$DYNAMIC_RE"
}

# Names stored in the file that are not in KNOWN, so `show` lists what it
# holds rather than only what it was compiled with.
stored_dynamic() {
  sed -n 's/^export \([A-Z0-9_]*\)=".*"$/\1/p' "$TOKENS" 2>/dev/null \
    | grep -E "$DYNAMIC_RE" | sort -u
}

get() { sed -n "s/^export $1=\"\(.*\)\"$/\1/p" "$TOKENS" 2>/dev/null | tail -1; }

# Rewrite in place so re-running never appends a duplicate export.
put() {
  local var="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -v "^export $var=" "$TOKENS" > "$tmp" 2>/dev/null || true
  printf 'export %s="%s"\n' "$var" "$value" >> "$tmp"
  mv "$tmp" "$TOKENS"; chmod 600 "$TOKENS"
}

drop() {
  local tmp; tmp="$(mktemp)"
  grep -v "^export $1=" "$TOKENS" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$TOKENS"; chmod 600 "$TOKENS"
}

mask() { local v="$1"; [ -n "$v" ] && printf '%s…%s (%d chars)' "${v:0:6}" "${v: -4}" "${#v}" || printf '—'; }

do_show() {
  printf '\n\033[1mtokens in %s\033[0m\n' "${TOKENS/#$ROOT\//}"
  local var desc value
  for entry in "${KNOWN[@]}"; do
    var="${entry%%:*}"; desc="${entry#*:}"; value="$(get "$var")"
    if [ -n "$value" ]; then
      printf '  %s✓%s %-26s %-22s %s\n' "$c_ok" "$c_off" "$var" "$(mask "$value")" "$c_dim$desc$c_off"
    else
      printf '  %s·%s %-26s %-22s %s\n' "$c_dim" "$c_off" "$var" "—" "$c_dim$desc$c_off"
    fi
  done
  for var in $(stored_dynamic); do
    value="$(get "$var")"
    printf '  %s✓%s %-26s %-22s %s\n' "$c_ok" "$c_off" "$var" "$(mask "$value")" \
      "$c_dim""private cargo registry""$c_off"
  done
  printf '\n  apply with: ./provision.sh --all --no-deploy\n\n'
}

do_set() {
  local var="$1" value
  is_known "$var" || die "unknown variable: $var (see ./agent-tokens.sh)"
  if [ -t 0 ]; then
    printf '  value for %s (input hidden): ' "$var"
    read -rs value; printf '\n'
  else
    # Piped in. Trim whitespace, and take the first line only: a `sed` that
    # matched twice would otherwise store the second value silently.
    read -r value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi
  [ -n "$value" ] || die "empty value - nothing stored (stdin gave nothing)"
  put "$var" "$value"
  ok "$var stored: $(mask "$value")"
}

do_claude() {
  command -v claude >/dev/null 2>&1 \
    || die "claude is not installed locally - install it, or use: ./agent-tokens.sh set CLAUDE_CODE_OAUTH_TOKEN"

  cat <<'MSG'

  `claude setup-token` opens a browser and prints a long-lived token at the
  end. It needs a Claude subscription, and one token serves the whole fleet.

MSG
  printf '  run it now? [Y/n] '; read -r reply
  case "${reply:-y}" in
    [nN]*) dim "skipped - paste an existing token instead" ;;
    *)     claude setup-token || dim "setup-token exited non-zero - you can still paste the token below" ;;
  esac

  printf '\n  paste the token (input hidden): '
  local value; read -rs value; printf '\n'
  [ -n "$value" ] || die "empty value - nothing stored"
  case "$value" in
    sk-ant-oat*|sk-ant-*) ;;
    *) dim "warning: that does not look like a Claude token, storing it anyway" ;;
  esac
  put CLAUDE_CODE_OAUTH_TOKEN "$value"
  ok "CLAUDE_CODE_OAUTH_TOKEN stored: $(mask "$value")"
}

init_store
case "${1:-show}" in
  show|"")  do_show ;;
  claude)   do_claude; do_show ;;
  set)      [ $# -ge 2 ] || die "usage: ./agent-tokens.sh set <VAR>"; do_set "$2"; do_show ;;
  unset)    [ $# -ge 2 ] || die "usage: ./agent-tokens.sh unset <VAR>"
            is_known "$2" || die "unknown variable: $2"
            drop "$2"; ok "$2 removed"; do_show ;;
  -h|--help) print_header_comment ;;
  *)        die "unknown command: $1 (try --help)" ;;
esac
