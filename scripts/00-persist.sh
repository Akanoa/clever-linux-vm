#!/usr/bin/env bash
# Wire the FS Bucket into the places that must survive a redeploy.
#
# One FS Bucket is shared by the whole fleet, so every VM is confined to
# vms/$VM_AGENT_NAME and cannot touch another box's workspace or state.
# shared/ is the one place they meet on purpose.
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

# This VM's private subtree of the shared bucket.
VM_ROOT="$PERSIST_ROOT/vms/${VM_AGENT_NAME:-default}"

# name:local-path pairs, snapshotted to $VM_ROOT/state/<name>
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
  VM_ROOT="$PERSIST_ROOT/vms/${VM_AGENT_NAME:-default}"
fi
mkdir -p "$VM_ROOT"/{workspace,state} "$PERSIST_ROOT/shared"

# Live workspace, written straight through to the bucket.
link_persistent "$VM_ROOT/workspace" "$HOME/workspace"

# Fleet-wide scratch: visible to every VM. Nothing writes here on its own,
# it is there for deliberately shared artefacts between boxes.
link_persistent "$PERSIST_ROOT/shared" "$HOME/shared"

restore_state() {
  local name path src
  for entry in "${SYNC_DIRS[@]}"; do
    name="${entry%%:*}"; path="${entry#*:}"; src="$VM_ROOT/state/$name"
    [ -d "$src" ] || continue
    mkdir -p "$path"
    rsync -a "${SYNC_EXCLUDES[@]}" "$src/" "$path/" 2>/dev/null \
      && log "restored $name -> $path"
  done
}

restore_state
log "shared bucket: $PERSIST_ROOT ($(df -h "$PERSIST_ROOT" 2>/dev/null | awk 'NR==2{print $2" total, "$4" free"}'))"
log "this VM's subtree: vms/${VM_AGENT_NAME:-default}"
