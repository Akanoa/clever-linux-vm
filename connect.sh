#!/usr/bin/env bash
# Local helper: open a shell on the vm-agent instance, or attach herdr's UI.
#
#   ./connect.sh            plain shell (clever ssh)
#   ./connect.sh --herdr    attach the local herdr client to the remote server
#   ./connect.sh --addr     just print host:port of the running instance
set -euo pipefail

APP="${APP:-vm-agent}"

# clever ssh resolves the instance address itself; for --herdr we need it
# explicitly, and it changes on every deploy.
instance_addr() {
  clever applications list >/dev/null 2>&1 || { echo "not logged in to Clever Cloud" >&2; exit 1; }
  # `clever ssh` prints the host it added to known_hosts on first contact;
  # asking the API directly is more reliable.
  clever status --app "$APP" --format json 2>/dev/null \
    | jq -r '.instances[]? | select(.state=="UP") | "\(.ip) \(.sshPort // 22)"' \
    | head -1
}

case "${1:-}" in
  --addr)
    instance_addr
    ;;
  --herdr)
    read -r host port <<<"$(instance_addr)"
    [ -n "${host:-}" ] || { echo "no running instance for $APP" >&2; exit 1; }
    exec herdr --remote "ssh://bas@${host}:${port}"
    ;;
  ""|--ssh)
    exec clever ssh --app "$APP"
    ;;
  *)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
