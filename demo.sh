#!/usr/bin/env bash
# Set up and run the fleet demo.
#
#   ./demo.sh start [vm-name]   provision if needed, then open the layout
#   ./demo.sh layout [vm-name]  just open the layout (VM must exist)
#   ./demo.sh stop [vm-name]    destroy the VM and restore the permission mode
#
# Nothing here edits your ~/.tmux.conf or fleet.conf. tmux runs on its own
# socket with its own prefix, and the permission mode is passed as an
# environment override, which fleet.conf's `: "${VAR:=default}"` already
# honours.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="${2:-demo-agent}"
SOCKET="vm-demo"
SESSION="fleet"
# Agents launched through the fleet have nobody at the keyboard: a
# permission prompt would stall the demo on the first shell command.
DEMO_PERMISSION_MODE="${DEMO_PERMISSION_MODE:-bypassPermissions}"

c_ok=$'\033[32m'; c_dim=$'\033[2m'; c_err=$'\033[31m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' $'\033[36m' "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok" "  ✓ $*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "  ✗ $*" "$c_off" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

vm_exists() {
  clever status --alias "$1" --format json >/dev/null 2>&1
}

cmd_start() {
  need clever; need jq; need tmux
  if vm_exists "$VM"; then
    ok "$VM already exists"
  else
    say "provisioning $VM (a few minutes)"
  fi
  # Applies to the whole fleet through the config provider; no file edited.
  CLAUDE_PERMISSION_MODE="$DEMO_PERMISSION_MODE" "$ROOT/provision.sh" "$VM" \
    || die "provisioning failed"
  ok "permission mode: $DEMO_PERMISSION_MODE"
  cmd_layout
}

# Wait until the pane is sitting at the remote shell prompt, rather than
# guessing with a fixed sleep - the SSH handshake time varies.
wait_for_remote_prompt() {
  local pane="$1" i
  for i in $(seq 1 40); do
    if tmux -L "$SOCKET" capture-pane -p -t "$pane" 2>/dev/null \
        | grep -qE 'bas@[0-9a-f-]+ +.*\$ *$'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cmd_layout() {
  need tmux
  vm_exists "$VM" || die "$VM does not exist - run: ./demo.sh start $VM"
  [ -f "$ROOT/.secrets/fleet.env" ] || die "no .secrets/fleet.env - run ./provision.sh --all first"

  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null

  # Left pane: control shell with `fleet` on PATH and the roster loaded.
  local rc; rc="$(mktemp)"
  cat > "$rc" <<RCEOF
[ -f ~/.bashrc ] && . ~/.bashrc
. "$ROOT/.secrets/fleet.env"
export PATH="$ROOT/tools:\$PATH"
cd "$ROOT"
clear
printf '\033[1mfleet control\033[0m  (prefix is \033[1mctrl+a\033[0m here, so ctrl+b reaches herdr on the right)\n\n'
printf '  fleet status\n  fleet start $VM worker\n  fleet prompt $VM/worker "..."\n  fleet read $VM/worker | tail -30\n  fleet agents\n\n'
RCEOF

  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
    "bash --rcfile '$rc'"
  # Prefix moved off ctrl+b so the remote herdr in the right pane keeps it.
  tmux -L "$SOCKET" set-option -g prefix C-a
  tmux -L "$SOCKET" unbind-key C-b
  tmux -L "$SOCKET" bind-key C-a send-prefix
  tmux -L "$SOCKET" set-option -g mouse on
  tmux -L "$SOCKET" set-option -g status-left "#[bold] fleet demo · $VM  "

  tmux -L "$SOCKET" split-window -h -t "$SESSION" \
    "clever ssh --alias '$VM'"

  say "waiting for the remote shell…"
  if wait_for_remote_prompt "$SESSION:0.1"; then
    tmux -L "$SOCKET" send-keys -t "$SESSION:0.1" "herdr" Enter
    ok "remote herdr attached"
  else
    printf '%s\n' "$c_dim  remote shell slow to answer - type 'herdr' in the right pane yourself$c_off"
  fi

  tmux -L "$SOCKET" select-pane -t "$SESSION:0.0"
  ok "attaching - detach with ctrl+a d"
  sleep 1
  tmux -L "$SOCKET" attach-session -t "$SESSION"
}

cmd_stop() {
  need clever
  tmux -L "$SOCKET" kill-server 2>/dev/null && ok "closed the demo tmux server"
  if vm_exists "$VM"; then
    "$ROOT/provision.sh" --destroy "$VM" --yes
  else
    printf '%s\n' "$c_dim  $VM does not exist$c_off"
  fi
  # Back to whatever fleet.conf says, since we only ever overrode the env.
  say "restoring the fleet permission mode from fleet.conf"
  "$ROOT/provision.sh" --all --no-deploy >/dev/null 2>&1 \
    && ok "permission mode restored" || true
}

case "${1:-start}" in
  start)  cmd_start ;;
  layout) cmd_layout ;;
  stop)   cmd_stop ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: ${1:-} (try --help)" ;;
esac
