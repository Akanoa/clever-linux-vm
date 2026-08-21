#!/usr/bin/env bash
# Start the herdr headless server, which owns every agent terminal.
#
# Attach from a laptop with:   clever ssh   then   herdr
# The server keeps panes alive across detach, so agents keep working while
# nobody is connected.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

have herdr || { log "herdr is not installed - skipping server start"; exit 1; }

if herdr status 2>/dev/null | grep -q 'status: running'; then
  log "herdr server already running"
  exit 0
fi

# Sockets live in ~/.config/herdr; clear stale ones left by the previous
# instance so the new server can bind.
rm -f "$HOME/.config/herdr"/*.sock 2>/dev/null || true
mkdir -p "$HOME/.config/herdr"

cd "$HOME/workspace" 2>/dev/null || cd "$HOME"
setsid nohup herdr server >> "$HOME/.config/herdr/herdr-boot.log" 2>&1 &

for _ in $(seq 1 30); do
  if herdr status 2>/dev/null | grep -q 'status: running'; then
    log "herdr server up ($(herdr --version))"
    exit 0
  fi
  sleep 1
done

log "ERROR: herdr server did not come up within 30s"
tail -n 20 "$HOME/.config/herdr/herdr-boot.log" 2>/dev/null | sed 's/^/[herdr] /'
exit 1
