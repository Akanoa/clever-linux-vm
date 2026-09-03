#!/usr/bin/env bash
# Wire this VM to its companion Docker daemon, if it has one.
#
# The box cannot run a container itself - the linux runtime has an empty
# subuid map and no cgroup delegation, so rootless podman cannot start and
# there is no daemon here to talk to. `./provision.sh --dockerd <vm>`
# creates a second app on the docker runtime with the instance socket
# mounted; this step installs the credentials for it and opens the tunnel.
#
# Absent VM_AGENT_DOCKERD the whole step is a no-op, which is what every
# VM provisioned without --dockerd sees.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

APP_HOME="${APP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
KEY="$HOME/.ssh/vm-agent-dockerd"
KNOWN="$HOME/.ssh/vm-agent-dockerd-known_hosts"
DOCKER_CLI_VERSION="${DOCKER_CLI_VERSION:-27.5.1}"

if [ -z "${VM_AGENT_DOCKERD:-}" ]; then
  log "no companion daemon for this VM (VM_AGENT_DOCKERD unset) - skipping"
  exit 0
fi

# ------------------------------------------------------------ credentials
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [ -n "${VM_AGENT_DOCKERD_KEY_B64:-}" ]; then
  printf '%s' "$VM_AGENT_DOCKERD_KEY_B64" | base64 -d > "$KEY.tmp" 2>/dev/null
  if [ -s "$KEY.tmp" ] && grep -q 'PRIVATE KEY' "$KEY.tmp"; then
    mv "$KEY.tmp" "$KEY"; chmod 600 "$KEY"
    log "dockerd key installed: $(ssh-keygen -yf "$KEY" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  else
    rm -f "$KEY.tmp"
    log "VM_AGENT_DOCKERD_KEY_B64 did not decode to a private key - tunnel will not open"
  fi
else
  log "VM_AGENT_DOCKERD is set but VM_AGENT_DOCKERD_KEY_B64 is not"
fi

# Pinned, not scanned: ssh-keyscan would trust whatever answers on that
# port, and the endpoint is on the public internet.
if [ -n "${VM_AGENT_DOCKERD_HOSTKEY:-}" ]; then
  printf '%s\n' "$VM_AGENT_DOCKERD_HOSTKEY" > "$KNOWN"
  chmod 600 "$KNOWN"
  log "dockerd host key pinned for $VM_AGENT_DOCKERD"
else
  log "no VM_AGENT_DOCKERD_HOSTKEY - the tunnel would have nothing to verify"
fi

# -------------------------------------------------------------- docker CLI
# The API alone is enough for tunnel.sh, but an agent that has a daemon
# will reach for `docker ps`, and finding nothing there reads as "no
# daemon" rather than "no client".
if have docker; then
  log "docker CLI present: $(docker --version 2>/dev/null)"
else
  url="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz"
  if curl -fsSL --max-time 120 "$url" -o /tmp/docker-cli.tgz 2>/dev/null \
     && tar -xzf /tmp/docker-cli.tgz -C /tmp docker/docker 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    install -m 755 /tmp/docker/docker "$HOME/.local/bin/docker"
    log "docker CLI installed: $("$HOME/.local/bin/docker" --version 2>/dev/null)"
  else
    log "could not install the docker CLI (tunnel.sh does not need it)"
  fi
  rm -rf /tmp/docker-cli.tgz /tmp/docker
fi

# ------------------------------------------------------------------ tunnel
if [ -f "$KEY" ] && [ -f "$KNOWN" ]; then
  if bash "$APP_HOME/tunnel.sh" start; then
    log "docker tunnel up - DOCKER_HOST is in /tmp/vm-agent-dockerd.env"
  else
    log "tunnel did not open; retry by hand with: $APP_HOME/tunnel.sh start"
  fi
else
  log "credentials incomplete - not opening the tunnel"
fi
