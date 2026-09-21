#!/usr/bin/env bash
# Give the VM what it needs to spawn agents into the fleet's Kubernetes
# cluster: kubectl, a kubeconfig, and the namespace `swarm` defaults to.
#
# Nothing here creates a cluster. ./cluster.sh does that from a laptop, on
# purpose: an agent holding these credentials can start and kill pods,
# which is the job, while creating and deleting clusters is a billing
# decision that belongs to a person. So this step is a no-op on a fleet
# that has no cluster, and it says so rather than failing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

export PATH="$HOME/.local/bin:$PATH"
KUBE_DIR="$HOME/.kube"
KUBECONFIG_FILE="$KUBE_DIR/config"

if [ -z "${VM_AGENT_KUBECONFIG_B64:-}" ]; then
  log "no VM_AGENT_KUBECONFIG_B64 - this fleet has no cluster wired up yet."
  log "  create one with ./cluster.sh create, then ./provision.sh --all --no-deploy"
  exit 0
fi

install_kubeconfig() {
  mkdir -p "$KUBE_DIR"; chmod 700 "$KUBE_DIR"
  printf '%s' "$VM_AGENT_KUBECONFIG_B64" | base64 -d > "$KUBECONFIG_FILE.tmp" 2>/dev/null
  # Judge by the content: a truncated or mis-encoded value decodes to
  # something, and a bad kubeconfig fails much later and much less
  # obviously than a missing one.
  if grep -qE '^(apiVersion|kind):' "$KUBECONFIG_FILE.tmp" 2>/dev/null; then
    mv "$KUBECONFIG_FILE.tmp" "$KUBECONFIG_FILE"
    chmod 600 "$KUBECONFIG_FILE"
    log "kubeconfig installed for cluster: $(awk '/server:/{print $2; exit}' "$KUBECONFIG_FILE")"
  else
    rm -f "$KUBECONFIG_FILE.tmp"
    log "ERROR: VM_AGENT_KUBECONFIG_B64 did not decode to a kubeconfig"
    return 1
  fi
}

install_kubectl() {
  have kubectl && { log "kubectl already present ($(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "?"'))"; return 0; }
  local ver
  ver="$(curl -fsSL --max-time 30 https://dl.k8s.io/release/stable.txt 2>/dev/null)"
  [ -n "$ver" ] || { log "could not resolve the current kubectl version"; return 1; }
  mkdir -p "$HOME/.local/bin"
  curl -fsSL --max-time 180 -o "$HOME/.local/bin/kubectl.tmp" \
    "https://dl.k8s.io/release/$ver/bin/linux/amd64/kubectl" || return 1
  chmod 755 "$HOME/.local/bin/kubectl.tmp"
  mv "$HOME/.local/bin/kubectl.tmp" "$HOME/.local/bin/kubectl"
  log "kubectl $ver installed"
}

step install_kubectl install_kubectl || true
step install_kubeconfig install_kubeconfig || true

if have kubectl && [ -s "$KUBECONFIG_FILE" ]; then
  if kubectl version --request-timeout=15s >/dev/null 2>&1; then
    log "cluster reachable - namespace ${VM_AGENT_K8S_NAMESPACE:-vm-agent}, image ${VM_AGENT_K8S_IMAGE:-<unset>}"
    log "  spawn an agent into it with: swarm run <name> \"...\""
  else
    log "WARNING: kubectl is installed and configured, but the cluster did not answer"
  fi
fi
