#!/usr/bin/env bash
# Shared helpers for the vm-agent boot scripts.

# Persistent root: the FS Bucket is mounted here by the platform.
# CC_FS_BUCKET paths are resolved *relative to APP_HOME*, so the mount
# lands at $APP_HOME/persistent rather than at an absolute /persistent.
PERSIST_ROOT="${PERSIST_ROOT:-${APP_HOME:-$HOME}/persistent}"
STATE_FILE="${STATE_FILE:-/tmp/vm-agent-state}"
BOOT_LOG="${BOOT_LOG:-/tmp/vm-agent-boot.log}"

log() {
  printf '[vm-agent] %s %s\n' "$(date -u +%H:%M:%S)" "$*"
}

# Record the current boot stage; the health endpoint serves this file.
stage() {
  printf '%s' "$1" > "$STATE_FILE"
  log "stage: $1"
}

# Run a step, logging failure without aborting the whole boot: a half
# provisioned box you can SSH into beats a dead one you cannot debug.
step() {
  local name="$1"; shift
  log "--> $name"
  if "$@"; then
    log "    ok: $name"
  else
    log "    FAILED: $name (continuing)"
    return 1
  fi
}

# Link $2 (a path in the app's home) to $1 (a dir on persistent storage),
# migrating any pre-existing local content into the persistent copy once.
link_persistent() {
  local target="$1" link="$2"
  mkdir -p "$target"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    cp -a "$link/." "$target/" 2>/dev/null || true
    rm -rf "$link"
  fi
  rm -f "$link"
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
}

have() { command -v "$1" >/dev/null 2>&1; }
