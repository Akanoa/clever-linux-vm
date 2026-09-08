#!/usr/bin/env bash
# vm-agent - entrypoint for the Clever Cloud "linux" runtime.
#
# Order matters: the health endpoint goes up first so the platform marks
# the instance healthy and `clever ssh` becomes available even if a later
# provisioning step fails. Nothing below is allowed to kill the process.
set -uo pipefail

export APP_HOME="${APP_HOME:-$(cd "$(dirname "$0")" && pwd)}"
export PERSIST_ROOT="${PERSIST_ROOT:-$APP_HOME/persistent}"
export STATE_FILE="/tmp/vm-agent-state"
export BOOT_LOG="/tmp/vm-agent-boot.log"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
export npm_config_prefix="$HOME/.local"
export SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-300}"

. "$APP_HOME/scripts/lib.sh"

# Everything printed here is mirrored to the platform log and to /logs.
exec > >(tee -a "$BOOT_LOG") 2>&1

stage "starting"
log "vm-agent booting (app=${CC_APP_NAME:-?} deployment=${CC_DEPLOYMENT_ID:-?})"

# --- 1. health endpoint, before anything that can fail -------------------
# Started through a function because it is restarted, not merely started -
# see the supervisor at the end of this file.
SHUTTING_DOWN=false
HEALTH_PID=""
start_health() {
  python3 "$APP_HOME/scripts/health-server.py" &
  HEALTH_PID=$!
}
start_health
log "health endpoint listening on 0.0.0.0:8080 (pid $HEALTH_PID)"

# --- 2. provisioning ----------------------------------------------------
stage "persistence"
bash "$APP_HOME/scripts/00-persist.sh"   || log "persistence step reported errors"

stage "toolchain"
bash "$APP_HOME/scripts/20-toolchain.sh" || log "toolchain step reported errors"

stage "secrets"
bash "$APP_HOME/scripts/10-secrets.sh"   || log "secrets step reported errors"

stage "agent-auth"
bash "$APP_HOME/scripts/15-agent-auth.sh" || log "agent auth step reported errors"

stage "toolbelt"
bash "$APP_HOME/scripts/25-toolbelt.sh" || log "toolbelt step reported errors"

stage "shell"
bash "$APP_HOME/scripts/30-shell.sh"     || log "shell step reported errors"

stage "herdr"
bash "$APP_HOME/scripts/40-herdr.sh"     || log "herdr step reported errors"

stage "dockerd"
bash "$APP_HOME/scripts/45-dockerd.sh"   || log "dockerd step reported errors"

stage "ready"
log "ready - attach with: clever ssh --app ${CC_APP_NAME:-vm-agent}   then run: herdr"

# --- 3. periodic state snapshot to the FS Bucket ------------------------
install -m 755 "$APP_HOME/tools/vm-snapshot" "$HOME/.local/bin/vm-snapshot" 2>/dev/null || true
(
  while true; do
    sleep "$SNAPSHOT_INTERVAL"
    "$HOME/.local/bin/vm-snapshot" --quiet
  done
) &
SNAPSHOT_PID=$!
log "state snapshot loop every ${SNAPSHOT_INTERVAL}s (pid $SNAPSHOT_PID)"

# Flush state to the bucket on a clean shutdown (redeploy, scale, stop).
shutdown() {
  # Tells the supervisor below that this exit is deliberate, so it does not
  # race to relaunch a server we are on our way to killing.
  SHUTTING_DOWN=true
  log "shutting down - flushing state to persistent storage"
  "$HOME/.local/bin/vm-snapshot" --quiet 2>/dev/null || true
  kill "$SNAPSHOT_PID" "$HEALTH_PID" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

# --- 4. supervise the health endpoint -----------------------------------
# This loop is the whole point of the file's structure. The health server is
# the app's foreground process: the platform's run command is `make run` ->
# `bash ./boot.sh`, so whatever this script waits on decides whether the
# instance is considered alive. Waiting on the server *once* made its death
# fatal and silent - the wait returned, boot.sh exited, the platform saw the
# run command terminate and redeployed the instance. A redeploy wipes local
# disk, so it took tmux, every running agent, /tmp and ~/.local with it; and
# since the server had been SIGKILLed rather than asked to stop, the trap
# below never ran and vm-snapshot never flushed. Three sessions were lost
# that way in one day.
#
# Nothing exotic is needed to trigger it: a broad `pkill -f` from an agent
# tidying up after a build matches the health server too, and a large build
# into the RAM-backed /tmp can OOM it just as well.
#
# So losing the server now costs a probe cycle and a relaunch, not the box.
# The backoff only guards against a server that cannot start at all, in
# which case the platform's own health check is the right thing to fail -
# an instance with no endpoint genuinely is unhealthy - but slowly enough
# that there is time to get in and look.
health_backoff=1
while :; do
  health_started=$SECONDS
  wait "$HEALTH_PID"
  rc=$?
  $SHUTTING_DOWN && break
  health_lifetime=$(( SECONDS - health_started ))

  # 128+n means a signal, which is the pkill case worth naming explicitly.
  if [ "$rc" -gt 128 ]; then
    log "health endpoint was killed by signal $((rc - 128)) - relaunching in ${health_backoff}s"
  else
    log "health endpoint exited (rc=$rc) - relaunching in ${health_backoff}s"
  fi
  sleep "$health_backoff"
  $SHUTTING_DOWN && break

  # A server that ran for a while and then died is an incident, not a
  # crash loop: reset, so the common case (something killed it) recovers in
  # a second. Only a server dying immediately, over and over, backs off -
  # measured on the run we just had, not in a subshell that cannot assign
  # back to this one.
  if [ "$health_lifetime" -ge 60 ]; then
    health_backoff=1
  elif [ "$health_backoff" -lt 30 ]; then
    health_backoff=$(( health_backoff * 2 ))
  fi

  start_health
  log "health endpoint back on 0.0.0.0:8080 (pid $HEALTH_PID)"
done
