#!/usr/bin/env bash
# Wire the FS Bucket into the places that must survive a redeploy.
#
# Clever Cloud instances are immutable: everything outside the mounted
# bucket is destroyed on every deploy. Two different strategies are used,
# because the bucket is NFS-backed:
#
#   * ~/workspace is a straight symlink onto the bucket. Repos and
#     uncommitted work are the thing we cannot afford to lose, so they get
#     written through immediately, at the cost of NFS latency.
#   * Agent state dirs are kept on local disk and rsync'd to the bucket.
#     They hold unix sockets, lock files and sqlite databases, none of
#     which behave on NFS.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# name:local-path pairs, snapshotted to $PERSIST_ROOT/state/<name>
SYNC_DIRS=(
  "claude:$HOME/.claude"
  "codex:$HOME/.codex"
  "opencode-data:$HOME/.local/share/opencode"
  "opencode-config:$HOME/.config/opencode"
  "herdr:$HOME/.config/herdr"
  "gh:$HOME/.config/gh"
  "glab:$HOME/.config/glab-cli"
)
# Sockets and logs are per-boot; restoring them confuses herdr on startup.
SYNC_EXCLUDES=(--exclude='*.sock' --exclude='*.lock' --exclude='*.log' --exclude='.plugins.lock')

if ! mountpoint -q "$PERSIST_ROOT" 2>/dev/null; then
  log "WARNING: $PERSIST_ROOT is not a mount point - CC_FS_BUCKET may be unset."
  log "         Falling back to ephemeral storage; work will NOT survive a redeploy."
  PERSIST_ROOT="$HOME/.vm-agent-ephemeral"
fi
mkdir -p "$PERSIST_ROOT"/{workspace,state}

# Live workspace, written straight through to the bucket.
link_persistent "$PERSIST_ROOT/workspace" "$HOME/workspace"

restore_state() {
  local name path src
  for entry in "${SYNC_DIRS[@]}"; do
    name="${entry%%:*}"; path="${entry#*:}"; src="$PERSIST_ROOT/state/$name"
    [ -d "$src" ] || continue
    mkdir -p "$path"
    rsync -a "${SYNC_EXCLUDES[@]}" "$src/" "$path/" 2>/dev/null \
      && log "restored $name -> $path"
  done
}

restore_state
log "persistent root: $PERSIST_ROOT ($(df -h "$PERSIST_ROOT" 2>/dev/null | awk 'NR==2{print $2" total, "$4" free"}'))"
