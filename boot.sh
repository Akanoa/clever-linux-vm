#!/usr/bin/env bash
# Probe boot: bring up health endpoint first, then dump environment facts.
set -uo pipefail

start_health() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server 8080 --bind 0.0.0.0 &
  elif command -v busybox >/dev/null 2>&1; then
    busybox httpd -f -p 0.0.0.0:8080 &
  else
    echo "PROBE: no python3/busybox available for health server" >&2
  fi
}

start_health
sleep 2

echo "=================== PROBE START ==================="
echo "--- whoami/id ---";      whoami; id
echo "--- pwd/HOME ---";       pwd; echo "HOME=$HOME"; ls -la "$HOME" 2>&1 | head -30
echo "--- os ---";             cat /etc/os-release 2>&1 | head -5; uname -a
echo "--- cpu/mem/disk ---";   nproc; free -m 2>&1 | head -3; df -h 2>&1 | head -15
echo "--- sudo ---";           sudo -n true 2>&1 && echo "SUDO_OK" || echo "SUDO_NO"
echo "--- apt ---";            command -v apt-get || echo "no apt-get"
echo "--- tools ---"
for t in mise curl wget git tar unzip xz gzip python3 node npm bun cargo rustc gcc make jq openssl ssh ssh-keygen fuse s3cmd aws gh glab tmux systemctl; do
  printf '%-12s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo '-')"
done
echo "--- mise ---";           mise --version 2>&1 | head -2; mise ls-remote node 2>&1 | tail -3
echo "--- env (CC_/BUCKET/CELLAR) ---"; env | grep -E '^(CC_|BUCKET_|CELLAR_|APP_|INSTANCE_|PORT|HOME|PATH)' | sed 's/\(SECRET\|PASSWORD\|KEY\)=.*/\1=<redacted>/'
echo "--- glibc ---";          ldd --version 2>&1 | head -1
echo "--- writable /usr/local ---"; touch /usr/local/bin/.probe 2>&1 && echo "WRITABLE" && rm -f /usr/local/bin/.probe || echo "NOT_WRITABLE"
echo "=================== PROBE END ==================="

# keep the app alive so we can SSH in
wait
