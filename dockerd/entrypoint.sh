#!/usr/bin/env bash
# Entrypoint for the vm-agent dockerd companion app.
#
# Nothing here is allowed to take the health endpoint down: the platform
# kills an instance that stops answering on 8080, and that would take the
# sshd - the only way in - with it. So 8080 goes up first and every later
# failure is logged and survived, exactly like boot.sh does on the VM side.
set -uo pipefail

log() { printf '[dockerd] %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------- health
cat > /usr/local/bin/health-response <<'RESPONSE'
#!/bin/sh
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 17\r\nConnection: close\r\n\r\nvm-agent dockerd\n'
RESPONSE
chmod +x /usr/local/bin/health-response
# The platform probes 8080 once a minute and closes as soon as it has the
# response, while socat still has the socket open for reading - so every
# single probe ends in "Connection reset by peer" (or "Broken pipe", when
# the close lands mid-write). Measured in the container: three probes,
# three errors, and draining the request first changes nothing, because
# the reset comes from the prober's close, not from the unread request.
# It is pure noise - one line a minute, for ever - so filter exactly those
# two and keep every other socat error, which is how a genuine failure
# (a port already bound, say) still reaches the log.
socat TCP-LISTEN:8080,fork,reuseaddr SYSTEM:/usr/local/bin/health-response \
  2> >(grep -vE 'Connection reset by peer|Broken pipe' >&2) &
HEALTH_PID=$!
log "health endpoint on 0.0.0.0:8080 (pid $HEALTH_PID)"

# Prove it actually bound. A health endpoint that silently fails to start
# does not fail the deployment - it hangs it: the platform waits on 8080
# forever and reports nothing. Better to say so in the first line of log.
for _ in 1 2 3 4 5; do
  (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && { log "8080 is listening"; break; }
  sleep 1
done
if ! (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
  log "FATAL: nothing is listening on 8080 - the deployment will hang waiting for it"
fi

# Keep the instance alive and reachable even when the reason it exists is
# missing - a dead instance cannot be diagnosed, and the platform would
# only restart it into the same failure.
fatal() {
  log "FATAL: $*"
  log "holding the health endpoint up so the instance stays diagnosable"
  wait "$HEALTH_PID"
  exit 1
}

# ---------------------------------------------------------------- socket
if [ ! -S /var/run/docker.sock ]; then
  fatal "/var/run/docker.sock is not mounted - set CC_MOUNT_DOCKER_SOCKET=true"
fi
if server="$(docker version --format '{{.Server.Version}}' 2>&1)"; then
  log "docker daemon reachable, server $server"
else
  log "WARNING: the socket is mounted but the daemon did not answer: $server"
fi

# ------------------------------------------------------------- host key
# A stable host key, supplied by provision.sh, so the VM can pin this
# endpoint in known_hosts. Redeploys rebuild the image; a key generated
# here would change on every one of them and every tunnel would then stop
# with a host key warning that looks exactly like an attack.
mkdir -p /etc/ssh
if [ -n "${DOCKERD_HOST_KEY_B64:-}" ]; then
  printf '%s' "$DOCKERD_HOST_KEY_B64" | base64 -d > /etc/ssh/ssh_host_ed25519_key 2>/dev/null
  if [ -s /etc/ssh/ssh_host_ed25519_key ]; then
    chmod 600 /etc/ssh/ssh_host_ed25519_key
    ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null \
      || fatal "DOCKERD_HOST_KEY_B64 does not decode to an ssh private key"
    log "host key: $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
  else
    fatal "DOCKERD_HOST_KEY_B64 is set but did not decode"
  fi
else
  ssh-keygen -A >/dev/null 2>&1
  log "WARNING: no DOCKERD_HOST_KEY_B64 - generated an ephemeral host key,"
  log "         which changes on every deploy and will break known_hosts"
fi

# --------------------------------------------------------- authorization
mkdir -p /root/.ssh; chmod 700 /root/.ssh
if [ -n "${DOCKERD_AUTHORIZED_KEYS_B64:-}" ]; then
  printf '%s' "$DOCKERD_AUTHORIZED_KEYS_B64" | base64 -d > /root/.ssh/authorized_keys 2>/dev/null
fi
if [ ! -s /root/.ssh/authorized_keys ]; then
  fatal "no authorized keys - set DOCKERD_AUTHORIZED_KEYS_B64 (base64 of the public keys)"
fi
chmod 600 /root/.ssh/authorized_keys
log "authorized keys: $(grep -c . /root/.ssh/authorized_keys)"

# ---------------------------------------------------------------- sshd
# Root, because the mounted socket is root-owned and this container exists
# for nothing else. Keys only, no shell traffic worth having: the client
# runs `ssh -N`, and everything it needs is a forward.
cat > /etc/ssh/sshd_config <<'SSHD'
Port 4040
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthorizedKeysFile /root/.ssh/authorized_keys

# The whole point of the endpoint.
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PermitOpen any

# Forwards must not become an open relay into the instance's network:
# bind only to loopback inside the container, never to its public side.
GatewayPorts no
X11Forwarding no
PermitTunnel no
AllowAgentForwarding no

ClientAliveInterval 30
ClientAliveCountMax 4
LoginGraceTime 20
LogLevel INFO
SSHD

# ---------------------------------------------------------------- janitor
# Testcontainers reaps its own containers through Ryuk, but a test run
# killed mid-flight leaks them, and this daemon is not ours alone - it also
# runs the app you are reading. So prune by Testcontainers' own label and
# nothing else; a blanket `docker system prune -a` here would evict the
# platform's image cache and the instance's own layers with it.
janitor() {
  local every="${DOCKERD_PRUNE_INTERVAL:-3600}" keep="${DOCKERD_PRUNE_KEEP:-6h}"
  local label='label=org.testcontainers=true'
  while sleep "$every"; do
    docker container prune -f --filter "$label" --filter "until=$keep" >/dev/null 2>&1
    docker volume    prune -f --filter "$label" >/dev/null 2>&1
    docker network   prune -f --filter "$label" --filter "until=$keep" >/dev/null 2>&1
    # Images are the pull cache and are shared with the platform, so this
    # one is opt-in and still only touches what nothing references.
    [ "${DOCKERD_PRUNE_IMAGES:-false}" = true ] \
      && docker image prune -af --filter "until=${DOCKERD_IMAGE_KEEP:-168h}" >/dev/null 2>&1
  done
}
janitor &
log "janitor every ${DOCKERD_PRUNE_INTERVAL:-3600}s (testcontainers-labelled resources only)"

# ------------------------------------------------------------------ run
log "sshd listening on 0.0.0.0:4040"
/usr/sbin/sshd -D -e &
SSHD_PID=$!

shutdown() { kill "$SSHD_PID" "$HEALTH_PID" 2>/dev/null; exit 0; }
trap shutdown TERM INT

# If sshd dies the app is useless, but staying up keeps the logs readable
# and the platform's restart is what fixes it.
wait "$SSHD_PID"
log "sshd exited - holding the health endpoint up"
wait "$HEALTH_PID"
