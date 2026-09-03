#!/usr/bin/env bash
# Borrow the Docker daemon of the companion app, from a fleet VM.
#
#   ./tunnel.sh start     open the tunnel and keep it open
#   ./tunnel.sh stop      close it
#   ./tunnel.sh status    is it up, and what is forwarded
#   ./tunnel.sh env       print the shell exports (eval "$(./tunnel.sh env)")
#   ./tunnel.sh doctor    start a real container and reach it, end to end
#
# The VM has no daemon of its own and cannot have one - rootless podman is
# dead on this runtime (no subuid map, no cgroup delegation). What it does
# have is an ssh client and no need for root to use it, so the daemon is
# borrowed over a forward instead:
#
#   * the API arrives on a forwarded unix socket, because that is the one
#     endpoint whose address never changes;
#   * every port Testcontainers publishes is forwarded, on demand, to the
#     *same* port number on this VM's loopback - so `localhost:49153` here
#     means what it means over there, and nothing has to be told about it.
#
# Which is why the second half exists at all. `ssh -L` is static and the
# ports are not: Testcontainers picks them when it starts a container. So
# this watches the daemon's own event stream and adds the forward as the
# container starts, which is the same trick a hosted Testcontainers agent
# plays, minus the hosting.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /tmp, not $HOME: on a fleet VM $HOME can be NFS, where a unix socket is
# not something you can bind, and the FS Bucket has no locking either.
SOCK="${VM_AGENT_DOCKERD_SOCK:-/tmp/vm-agent-dockerd.sock}"
CTL="/tmp/vm-agent-dockerd.ctl"
ENV_FILE="/tmp/vm-agent-dockerd.env"
PIDFILE="/tmp/vm-agent-dockerd.pid"
LOG="/tmp/vm-agent-dockerd.log"
FWDIR="/tmp/vm-agent-dockerd.fw"
PROBE_ID=""

KEY="${VM_AGENT_DOCKERD_KEY:-$HOME/.ssh/vm-agent-dockerd}"
KNOWN="${VM_AGENT_DOCKERD_KNOWN_HOSTS:-$HOME/.ssh/vm-agent-dockerd-known_hosts}"

c_ok=$'\033[32m'; c_do=$'\033[36m'; c_err=$'\033[31m'; c_skip=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_do"   "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok"   "  ✓ $*" "$c_off"; }
skip() { printf '%s%s%s\n' "$c_skip" "  · $*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err"  "  ✗ $*" "$c_off" >&2; exit 1; }
tlog() { printf '[tunnel] %s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG"; }

endpoint() {
  local ep="${VM_AGENT_DOCKERD:-}"
  [ -n "$ep" ] || die "VM_AGENT_DOCKERD is not set - no companion daemon for this VM.
    Create one with:  ./provision.sh --dockerd \$VM_AGENT_NAME"
  HOST="${ep%%:*}"; PORT="${ep##*:}"
  [ "$HOST" != "$ep" ] && [ -n "$PORT" ] || die "VM_AGENT_DOCKERD must be host:port, got '$ep'"
}

# The daemon's own API, over the forwarded socket. No version prefix: the
# daemon then answers with its newest, which is what its own client would get.
api() { curl -s --max-time 15 --unix-socket "$SOCK" "http://localhost$1"; }
api_post() {
  curl -s --max-time 120 --unix-socket "$SOCK" -X POST \
    -H 'Content-Type: application/json' ${2:+-d "$2"} "http://localhost$1"
}

master_up() { [ -S "$CTL" ] && ssh -S "$CTL" -O check placeholder >/dev/null 2>&1; }

# --------------------------------------------------------------- forwards
# One local listener per published port, at the same number, so nothing on
# this side has to translate. `ssh -O forward` adds them to the running
# master, which is what makes them dynamic.
# 8080 and 4040 are the platform's own two ports: the companion answers the
# health check on one and runs its sshd on the other, and on this side 8080
# is the VM's own health server. They are never a test container's port, and
# forwarding them only produces a failure that reads like a real one.
fw_reserved() { [ "$1" = 8080 ] || [ "$1" = 4040 ]; }

fw_add() {
  local p="$1"
  if fw_reserved "$p"; then tlog "forward +$p skipped (platform port)"; return; fi
  if ssh -S "$CTL" -O forward -L "127.0.0.1:$p:$GATEWAY:$p" placeholder >/dev/null 2>&1; then
    tlog "forward +$p -> $GATEWAY:$p"
  else
    # Almost always something already listening on $p here - which would
    # then answer the test instead of the container.
    tlog "forward +$p FAILED - is 127.0.0.1:$p already in use on this box?"
  fi
}
fw_del() {
  local p="$1"
  fw_reserved "$p" && return
  ssh -S "$CTL" -O cancel -L "127.0.0.1:$p:$GATEWAY:$p" placeholder >/dev/null 2>&1
  tlog "forward -$p"
}

container_ports() {  # $1 container id -> published host ports, one per line
  api "/containers/$1/json" \
    | jq -r '.NetworkSettings.Ports // {} | to_entries[] | .value // [] | .[]? | .HostPort' \
    | grep -E '^[0-9]+$' | sort -u
}

# The ports of a container are gone from the API by the time it is
# destroyed, so remember what was opened for it while it is still there.
remember() { mkdir -p "$FWDIR"; printf '%s\n' "$2" > "$FWDIR/$1"; }
forget()   { rm -f "$FWDIR/$1"; }

# ---------------------------------------------------------------- connect
# Everything that must happen once the socket is live: learn where the
# published ports actually land, publish the environment, and catch up on
# containers that were already running.
on_connect() {
  # Published ports bind 0.0.0.0 on the instance, so the bridge gateway
  # reaches them whether this daemon's app container sits on the bridge or
  # on the host network. Ask the daemon rather than assume the address:
  # 172.17.0.1 is only the default, not a promise.
  GATEWAY="$(api /networks/bridge | jq -r '.IPAM.Config[0].Gateway // empty' 2>/dev/null)"
  if [ -z "$GATEWAY" ]; then
    GATEWAY=127.0.0.1
    tlog "could not read the bridge gateway - falling back to $GATEWAY"
  fi
  tlog "connected, published ports reachable at $GATEWAY"

  cat > "$ENV_FILE" <<EOF
# Generated by tunnel.sh - the borrowed daemon, as this VM sees it.
export DOCKER_HOST="unix://$SOCK"
export TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1
export VM_AGENT_DOCKERD_GATEWAY="$GATEWAY"
EOF

  local id ports
  while read -r id; do
    [ -n "$id" ] || continue
    ports="$(container_ports "$id")"
    [ -n "$ports" ] || continue
    remember "$id" "$ports"
    while read -r p; do [ -n "$p" ] && fw_add "$p"; done <<< "$ports"
  done < <(api /containers/json | jq -r '.[]?.Id')
}

# Docker's event stream, unfiltered - server-side filters have to be
# url-encoded JSON and the volume here does not justify it.
#
# `.Action` and `.Actor.ID`, not `.status` and `.id`: the flat legacy pair
# is gone from the modern API (docker 29 / api 1.55 emits neither), and
# reading the old names gets you a stream that parses cleanly and matches
# nothing at all - every container starts unforwarded and every test times
# out against a port that was never opened. The fallbacks keep an older
# daemon working.
watch_events() {
  local line action id ports
  curl -sN --unix-socket "$SOCK" "http://localhost/events" | while read -r line; do
    [ -n "$line" ] || continue
    read -r action id <<< "$(printf '%s' "$line" \
      | jq -r 'select(.Type=="container") | "\(.Action // .status // "") \(.Actor.ID // .id // "")"' 2>/dev/null)"
    [ -n "$action" ] && [ -n "$id" ] || continue
    case "$action" in
      start)
        ports="$(container_ports "$id")"
        [ -n "$ports" ] || continue
        remember "$id" "$ports"
        while read -r p; do [ -n "$p" ] && fw_add "$p"; done <<< "$ports"
        ;;
      die|destroy)
        [ -f "$FWDIR/$id" ] || continue
        while read -r p; do [ -n "$p" ] && fw_del "$p"; done < "$FWDIR/$id"
        forget "$id"
        ;;
    esac
  done
}

# -------------------------------------------------------------- supervisor
# Runs detached. The tunnel is not something an agent should have to think
# about, so a dropped connection reconnects and re-establishes the forwards
# for whatever is running rather than leaving a half-working socket behind.
supervise() {
  endpoint
  trap 'kill $(jobs -p) 2>/dev/null; rm -f "$SOCK" "$PIDFILE"; exit 0' TERM INT
  local backoff=2
  while :; do
    # A stale socket file makes the forward fail outright, and
    # ExitOnForwardFailure then kills the connection we just made.
    rm -f "$SOCK"
    tlog "connecting to $HOST:$PORT"
    # -F /dev/null: ~/.ssh/config on a fleet VM pins the *commit* key for
    # `Host *`, which this connection would then offer first and burn an
    # auth attempt on. Nothing in that file applies here.
    ssh -N -M -S "$CTL" -F /dev/null \
        -i "$KEY" -p "$PORT" \
        -o IdentitiesOnly=yes \
        -o UserKnownHostsFile="$KNOWN" \
        -o StrictHostKeyChecking=yes \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -L "$SOCK:/var/run/docker.sock" \
        "root@$HOST" &
    local ssh_pid=$!

    local waited=0
    while [ ! -S "$SOCK" ] && kill -0 "$ssh_pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
      sleep 1; waited=$((waited + 1))
    done

    if [ -S "$SOCK" ] && master_up; then
      backoff=2
      on_connect
      watch_events &
      local watch_pid=$!
      wait "$ssh_pid"
      kill "$watch_pid" 2>/dev/null
      tlog "tunnel closed"
    else
      kill "$ssh_pid" 2>/dev/null
      tlog "could not open the tunnel (see $LOG); retrying in ${backoff}s"
    fi

    rm -rf "$FWDIR"
    sleep "$backoff"
    [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
  done
}

# ------------------------------------------------------------------ verbs
do_start() {
  endpoint
  need_files
  if is_running; then skip "tunnel already up (pid $(cat "$PIDFILE"))"; do_status; return; fi
  rm -f "$LOG"; mkdir -p "$FWDIR"
  say "opening a tunnel to $HOST:$PORT"
  setsid "$ROOT/tunnel.sh" --supervise >/dev/null 2>&1 < /dev/null &
  # $! is only the supervisor when setsid execs in place; when it forks
  # instead, that pid is already gone and a stale pidfile would let the
  # next `start` run a second supervisor against the same socket.
  echo $! > "$PIDFILE"
  local waited=0 real
  sleep 1
  real="$(pgrep -f 'tunnel\.sh --supervise' 2>/dev/null | head -1)"
  [ -n "$real" ] && echo "$real" > "$PIDFILE"
  while [ ! -S "$SOCK" ] && [ "$waited" -lt 40 ]; do sleep 1; waited=$((waited + 1)); done
  if [ -S "$SOCK" ] && api /_ping >/dev/null 2>&1; then
    ok "daemon reachable: $(api /version | jq -r '"docker " + .Version + " (api " + .ApiVersion + ")"')"
    ok "DOCKER_HOST=unix://$SOCK"
    skip "shells pick it up from $ENV_FILE; this one: eval \"\$($0 env)\""
  else
    printf '%s\n' "$c_err  ✗ the tunnel did not come up - last lines of $LOG:$c_off" >&2
    tail -5 "$LOG" 2>/dev/null >&2
    exit 1
  fi
}

do_stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 1
    pkill -f "tunnel.sh --supervise" 2>/dev/null
    ok "tunnel closed"
  else
    skip "not running"
  fi
  rm -f "$PIDFILE" "$SOCK" "$ENV_FILE"; rm -rf "$FWDIR"
}

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

do_status() {
  if ! is_running; then skip "tunnel is not running"; return 1; fi
  if ! api /_ping >/dev/null 2>&1; then
    printf '%s\n' "$c_err  ! supervisor is up but the daemon does not answer$c_off"
    tail -3 "$LOG" 2>/dev/null
    return 1
  fi
  ok "$(api /version | jq -r '"docker " + .Version')  via ${VM_AGENT_DOCKERD:-?}"
  local n
  n="$(api /containers/json | jq -r 'length')"
  printf '    %s container(s) running, published ports on this VM:\n' "$n"
  api /containers/json | jq -r '.[]? | . as $c | (.Ports[]? | select(.PublicPort)
      | "      127.0.0.1:\(.PublicPort) -> \($c.Names[0] | ltrimstr("/")) \(.PrivatePort)/\(.Type)")' \
    | sort -u
}

do_env() {
  [ -f "$ENV_FILE" ] || die "no tunnel is up - run '$0 start' first"
  cat "$ENV_FILE"
}

need_files() {
  command -v ssh   >/dev/null || die "ssh is required"
  command -v curl  >/dev/null || die "curl is required"
  command -v jq    >/dev/null || die "jq is required"
  [ -f "$KEY" ]   || die "no client key at $KEY - the VM gets it from VM_AGENT_DOCKERD_KEY_B64"
  [ -f "$KNOWN" ] || die "no pinned host key at $KNOWN - it comes from VM_AGENT_DOCKERD_HOSTKEY"
  chmod 600 "$KEY" 2>/dev/null
}

# End to end, with a real container: the only check that proves the port
# path works, which is the half of this that is not just `ssh -L`.
do_doctor() {
  is_running || die "tunnel is not running - '$0 start' first"
  api /_ping >/dev/null 2>&1 || die "the daemon does not answer over $SOCK"
  ok "daemon answers"

  local img="traefik/whoami:latest"
  say "pulling $img"
  api_post "/images/create?fromImage=traefik%2Fwhoami&tag=latest" >/dev/null \
    || die "could not pull $img"

  say "starting a container with a published port"
  # Global, not local: the EXIT trap below fires after this function has
  # returned, where a local is out of scope - which under `set -u` turns
  # the cleanup into an error and leaves the probe container running.
  PROBE_ID="$(api_post /containers/create '{
      "Image":"traefik/whoami",
      "Labels":{"vm-agent.doctor":"true"},
      "ExposedPorts":{"80/tcp":{}},
      "HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}]}}
    }' | jq -r '.Id // empty')"
  [ -n "$PROBE_ID" ] || die "could not create the probe container"
  cleanup_probe() {
    curl -s --unix-socket "$SOCK" -X DELETE \
      "http://localhost/containers/$PROBE_ID?force=1" >/dev/null 2>&1
  }
  trap cleanup_probe EXIT

  api_post "/containers/$PROBE_ID/start" >/dev/null
  local port="" waited=0
  while [ -z "$port" ] && [ "$waited" -lt 15 ]; do
    port="$(container_ports "$PROBE_ID" | head -1)"
    [ -n "$port" ] || { sleep 1; waited=$((waited + 1)); }
  done
  [ -n "$port" ] || die "the container started but published no port"
  ok "container published port $port on the daemon side"

  # The forward is added by the event watcher; give it a moment to land.
  local tries=0 body=""
  while [ "$tries" -lt 15 ]; do
    body="$(curl -s --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null)"
    [ -n "$body" ] && break
    sleep 1; tries=$((tries + 1))
  done
  if [ -n "$body" ]; then
    ok "reached it at 127.0.0.1:$port from this VM"
    ok "the port path works - Testcontainers will find its containers on localhost"
  else
    printf '%s\n' "$c_err  ✗ the container is up but 127.0.0.1:$port is not answering$c_off" >&2
    printf '%s\n' "$c_err    forwards land on $(sed -n 's/^export VM_AGENT_DOCKERD_GATEWAY="\(.*\)"$/\1/p' "$ENV_FILE"); see $LOG$c_off" >&2
    exit 1
  fi
}

case "${1:-status}" in
  start)       do_start ;;
  stop)        do_stop ;;
  restart)     do_stop; do_start ;;
  status)      do_status ;;
  env)         do_env ;;
  doctor)      do_doctor ;;
  --supervise) supervise ;;   # internal: the detached half of `start`
  -h|--help)   awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0" ;;
  *)           die "unknown command: $1 (try --help)" ;;
esac
