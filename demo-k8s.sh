#!/usr/bin/env bash
# Set up and run the Kubernetes demo: agents as pods rather than as boxes.
#
#   ./demo-k8s.sh start [name]   create the demo pod, then open the layout
#   ./demo-k8s.sh layout [name]  just open the layout (the pod must exist)
#   ./demo-k8s.sh fanout [n]     dispatch n one-shot Jobs, the disposable shape
#   ./demo-k8s.sh stop [name]    delete the demo pod and the fan-out jobs
#
# demo.sh shows one long-lived VM. This shows the other half: a pod that
# starts in seconds and a handful of Jobs that answer and evaporate, side
# by side, so the difference is visible rather than described.
#
# It creates nothing billable beyond the pods themselves - the cluster has
# to exist already, because a control plane is a decision rather than a
# demo step. `./cluster.sh create` makes one; this refuses without it.
#
# Nothing here edits your ~/.tmux.conf, fleet.conf or the cluster's shared
# secret. tmux runs on its own socket with its own prefix, and the
# permission mode is a per-pod `--env` override, which beats the namespace
# secret for these pods only and leaves every other agent alone.
set -uo pipefail

print_header_comment() {
  # The full leading comment block - not a fixed line range, which silently
  # truncates the help as soon as anyone adds a line to it.
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD="${2:-demo-agent}"
SOCKET="k8s-demo"
SESSION="swarm"
FAN_PREFIX="demo-fan"
# Agents in a pod have nobody at the keyboard either, so the same rule as
# demo.sh applies - except this one does not have to change the fleet to
# get it, because `env` overrides `envFrom` in the manifest.
DEMO_PERMISSION_MODE="${DEMO_PERMISSION_MODE:-bypassPermissions}"

c_ok=$'\033[32m'; c_dim=$'\033[2m'; c_err=$'\033[31m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' $'\033[36m' "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok" "  ✓ $*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err" "  ✗ $*" "$c_off" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

# Overridable so the layout can be exercised without a live cluster.
SWARM="${SWARM:-$ROOT/tools/swarm}"

# swarm resolves the cluster from .secrets/k8s.env when it is run out of
# the repository, which is how this works on a laptop with no VM_AGENT_*
# in the environment.
swarm() { "$SWARM" "$@"; }

pod_running() { swarm status "$1" >/dev/null 2>&1; }

# Everything the demo needs to already be true, checked in the order a
# person would fix it. `cluster.sh doctor` says the same thing at more
# length; this says which single command to run next.
PREFLIGHT_DONE=false
preflight() {
  $PREFLIGHT_DONE && return 0
  [ -x "$SWARM" ] || die "tools/swarm is missing or not executable"
  [ -f "$ROOT/.secrets/k8s.env" ] || die "no .secrets/k8s.env - this fleet has no cluster yet.
    ./cluster.sh create --yes     build one (it bills while it exists)
    ./cluster.sh image  --yes     build and publish the agent image"
  # shellcheck disable=SC1091
  . "$ROOT/.secrets/k8s.env"
  [ -n "${VM_AGENT_K8S_IMAGE:-}" ] || die "no agent image published yet - run: ./cluster.sh image --yes"
  swarm ls >/dev/null 2>&1 || die "the cluster is not answering - check: ./cluster.sh doctor"
  ok "cluster reachable, image ${VM_AGENT_K8S_IMAGE##*/}"
  PREFLIGHT_DONE=true
}

cmd_start() {
  need tmux; need jq
  preflight
  if pod_running "$POD"; then
    ok "$POD is already running"
  else
    say "starting $POD (seconds, not minutes - the image is prebuilt)"
    swarm start "$POD" --env "CLAUDE_PERMISSION_MODE=$DEMO_PERMISSION_MODE" \
      || die "could not start $POD"
    ok "permission mode: $DEMO_PERMISSION_MODE (this pod only)"
  fi
  cmd_layout
}

cmd_fanout() {
  local n="${2:-3}" i name
  case "$n" in ''|*[!0-9]*) die "fanout takes a count, got '$n'" ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le 20 ] || die "fanout takes 1..20"
  preflight
  say "dispatching $n one-shot Jobs"
  for i in $(seq 1 "$n"); do
    name="$FAN_PREFIX-$i"
    swarm kill "$name" >/dev/null 2>&1
    swarm run "$name" \
      "You are agent number $i of $n running in parallel in a Kubernetes cluster.
Reply with two or three sentences on what number $i is interesting for -
mathematically, historically, whatever you like. Nothing else." \
      --env "CLAUDE_PERMISSION_MODE=$DEMO_PERMISSION_MODE" \
      --timeout 300 --ttl 1800 >/dev/null \
      && ok "$name dispatched" \
      || printf '%s\n' "$c_err  ✗ $name failed to dispatch$c_off"
  done
  printf '\n'
  printf '%s\n' "$c_dim  watch:   swarm ls$c_off"
  printf '%s\n' "$c_dim  collect: swarm fetch $FAN_PREFIX-1$c_off"
  printf '%s\n' "$c_dim  they delete themselves 30 minutes after finishing$c_off"
}

cmd_layout() {
  need tmux
  preflight
  pod_running "$POD" || die "$POD is not running - run: ./demo-k8s.sh start $POD"

  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null

  # The panes need the cluster in their environment, and a login shell on
  # this machine will not have it. One directory of generated rc files,
  # kept rather than trapped away: tmux reads them after this script exits.
  local d; d="$(mktemp -d)"

  cat > "$d/control" <<RCEOF
[ -f ~/.bashrc ] && . ~/.bashrc
. "$ROOT/.secrets/k8s.env"
[ -f "$ROOT/.secrets/fleet.env" ] && . "$ROOT/.secrets/fleet.env"
export PATH="$ROOT/tools:\$PATH"
cd "$ROOT"
clear
printf '\033[1mswarm control\033[0m  (prefix is \033[1mctrl+a\033[0m here, so ctrl+b reaches herdr below-right)\n\n'
printf '\033[2mthe disposable shape - each one answers and deletes itself:\033[0m\n'
printf '  ./demo-k8s.sh fanout 5\n  swarm fetch $FAN_PREFIX-1\n\n'
printf '\033[2mthe driveable shape - $POD, already running, agent "main":\033[0m\n'
printf '  swarm prompt $POD "what files are in this directory?"\n'
printf '  swarm read $POD | tail -30\n'
printf '  swarm task $POD "..."   then   swarm fetch $POD\n\n'
printf '\033[2mand the VMs, if this fleet has any:\033[0m\n'
printf '  fleet status\n\n'
RCEOF

  # A plain loop rather than `watch`: one less thing that has to be
  # installed, and it keeps swarm's own colours.
  cat > "$d/watch" <<RCEOF
. "$ROOT/.secrets/k8s.env"
export PATH="$ROOT/tools:\$PATH"
while true; do
  clear
  printf '\033[1m  pods in %s\033[0m  \033[2m(refreshing every 5s)\033[0m\n\n' "\${VM_AGENT_K8S_NAMESPACE:-vm-agent}"
  swarm ls 2>&1
  sleep 5
done
RCEOF

  # Not `exec swarm attach`. A pane whose command exits is removed by
  # tmux without a word, so an attach that fails - or a herdr the user
  # simply detached from with ctrl+b q - would leave a two-pane layout and
  # no explanation for the missing third. Fall back to a shell that says
  # what happened and can retry.
  cat > "$d/attach" <<RCEOF
. "$ROOT/.secrets/k8s.env"
export PATH="$ROOT/tools:\$PATH"
if ! swarm attach "$POD"; then
  printf '\n\033[31m  could not attach to $POD.\033[0m\n'
  printf '  it may still be starting - check with: swarm ls\n'
fi
printf '\n\033[2m  this pane is a shell; reattach with: swarm attach $POD\033[0m\n\n'
exec bash
RCEOF

  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
    "bash --rcfile '$d/control'"
  # Prefix moved off ctrl+b so the herdr running inside the pod keeps it.
  # escape-time for the same reason as demo.sh: tmux's 500ms default
  # delays every ESC-prefixed key, which is every arrow and Alt combo.
  tmux -L "$SOCKET" set-option -g escape-time 10
  tmux -L "$SOCKET" set-option -g prefix C-a
  tmux -L "$SOCKET" unbind-key C-b
  tmux -L "$SOCKET" bind-key C-a send-prefix
  tmux -L "$SOCKET" set-option -g mouse on
  tmux -L "$SOCKET" set-option -g status-left "#[bold] swarm demo · $POD  "

  # Right column: what is running on top, the pod's own herdr below. The
  # top pane is the point of the demo - it is where pods appear and vanish.
  tmux -L "$SOCKET" split-window -h -t "$SESSION" "bash --rcfile '$d/watch'"
  tmux -L "$SOCKET" split-window -v -t "$SESSION:0.1" -l 65% "bash '$d/attach'"

  tmux -L "$SOCKET" select-pane -t "$SESSION:0.0"
  ok "attaching - detach with ctrl+a d"
  sleep 1
  tmux -L "$SOCKET" attach-session -t "$SESSION"
}

cmd_stop() {
  tmux -L "$SOCKET" kill-server 2>/dev/null && ok "closed the demo tmux server"
  if [ -f "$ROOT/.secrets/k8s.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/.secrets/k8s.env"
    swarm kill "$POD" 2>/dev/null | sed 's/^/ /'
    # The fan-out jobs reap themselves on their TTL, but "stop" should
    # mean stopped now, not in half an hour.
    # `swarm kill` reports a miss and still exits 0 - by design, so that
    # killing several names is not a partial failure - so count what it
    # said rather than what it returned.
    local n=0 i out
    for i in $(seq 1 20); do
      out="$(swarm kill "$FAN_PREFIX-$i" 2>/dev/null)"
      printf '%s' "$out" | grep -q deleted && n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] && ok "deleted $n fan-out job(s)" \
      || printf '%s\n' "$c_dim  no fan-out jobs to delete$c_off"
  else
    printf '%s\n' "$c_dim  no .secrets/k8s.env - nothing to clean up$c_off"
  fi
  # Nothing fleet-wide was changed, so unlike demo.sh there is nothing to
  # put back: the permission mode was a per-pod override and it left with
  # the pods.
  printf '\n'
  printf '%s\n' "$c_dim  the cluster itself is still running, and still billing.$c_off"
  printf '%s\n' "$c_dim  remove it with: ./cluster.sh destroy --yes$c_off"
}

# `demo-k8s.sh <verb> --help` too, not just the bare form.
case "${2:-}" in -h|--help) print_header_comment; exit 0 ;; esac

case "${1:-start}" in
  start)  cmd_start ;;
  layout) cmd_layout ;;
  fanout) cmd_fanout "$@" ;;
  stop)   cmd_stop ;;
  -h|--help) print_header_comment ;;
  *) die "unknown command: ${1:-} (try --help)" ;;
esac
