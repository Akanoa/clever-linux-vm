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
python3 "$APP_HOME/scripts/health-server.py" &
HEALTH_PID=$!
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

stage "shell"
bash "$APP_HOME/scripts/30-shell.sh"     || log "shell step reported errors"

stage "herdr"
bash "$APP_HOME/scripts/40-herdr.sh"     || log "herdr step reported errors"

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
  log "shutting down - flushing state to persistent storage"
  "$HOME/.local/bin/vm-snapshot" --quiet 2>/dev/null || true
  kill "$SNAPSHOT_PID" "$HEALTH_PID" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

# The health server is the process that must stay alive; if it dies the
# platform would report the instance as down anyway.
wait "$HEALTH_PID"
