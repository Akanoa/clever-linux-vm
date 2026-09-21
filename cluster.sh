#!/usr/bin/env bash
# Build the fleet's Kubernetes side: the cluster, the agent image, and the
# namespace the pods are spawned into.
#
# provision.sh builds pets - VMs that boot for a minute, keep a workspace
# on a bucket and are worth reattaching to tomorrow. This builds the other
# half: a cluster where an agent starts in seconds from a prebuilt image,
# is told one thing, and is thrown away. `swarm` is what drives it
# afterwards, on a VM or here.
#
#   ./cluster.sh create              create the cluster and wire it up
#   ./cluster.sh image               build the agent image, push it to GitLab
#   ./cluster.sh bootstrap           namespace, pull secret, agent secrets
#   ./cluster.sh secrets             refresh the agent secrets only
#   ./cluster.sh status              cluster, nodes, and what is running
#   ./cluster.sh kubeconfig          (re)fetch it into .secrets/kubeconfig.yaml
#   ./cluster.sh storage             enable persistent volumes (Ceph CSI)
#   ./cluster.sh doctor              check the whole path end to end
#   ./cluster.sh destroy --yes       delete the cluster
#
# Everything is idempotent, like provision.sh: each step checks the state
# it wants before touching anything, so re-running is a no-op and
# re-running after a failure resumes.
#
# The one prerequisite is the fleet's shared Configuration provider, which
# is where a pod's credentials come from. That is an add-on, not a VM:
# `./provision.sh --shared-only` creates it and creates no box, so a fleet
# whose agents are all pods never needs one.
#
# Options
#   --org <id|name>   organisation to build in (default: fleet.conf, else
#                     your personal space)
#   --cluster <name>  cluster name (default: <FLEET_NAME>-k8s)
#   --namespace <ns>  namespace for the agents (default: vm-agent)
#   --project <path>  gitlab.com project whose registry holds the image
#   --tag <tag>       image tag (default: latest)
#   --no-push         image: build only, do not push
#   --no-wait         create: return as soon as the cluster is accepted
#   --yes, -y         do not ask before creating or destroying anything
#
# This script does NOT write to the fleet's shared configuration. Adding
# the kubeconfig to it restarts every linked VM and kills the panes of
# whatever the agents were doing, and provision.sh is the one place that
# knows how to check for that first. So the handover is:
#
#   ./cluster.sh create              # cluster + .secrets/kubeconfig.yaml
#   ./provision.sh --all --no-deploy # publish it to the fleet, when quiet
#
# After which every VM has kubectl, a kubeconfig and `swarm`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$ROOT/.secrets"
KUBECONFIG_PATH="$SECRETS_DIR/kubeconfig.yaml"
REGISTRY_ENV="$SECRETS_DIR/registry.env"

[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf"
[ -f "$SECRETS_DIR/tokens.env" ] && . "$SECRETS_DIR/tokens.env"
[ -f "$REGISTRY_ENV" ] && . "$REGISTRY_ENV"

FLEET_NAME="${FLEET_NAME:-vm-agent}"
CLUSTER="${K8S_CLUSTER:-$FLEET_NAME-k8s}"
NAMESPACE="${K8S_NAMESPACE:-vm-agent}"
CONFIG_ADDON="${CONFIG_ADDON:-vm-agent-config}"
CELLAR_ADDON="${CELLAR_ADDON:-vm-agent-cellar}"
CELLAR_BUCKET_NAME="${CELLAR_BUCKET_NAME:-}"
GITLAB_HOST_VALUE="${GITLAB_HOST:-gitlab.com}"
IMAGE_PROJECT="${K8S_IMAGE_PROJECT:-}"
IMAGE_NAME="${K8S_IMAGE_NAME:-agent}"
IMAGE_TAG="${K8S_IMAGE_TAG:-latest}"
# gitlab.com's registry is on its own host; a self-managed instance
# usually puts it on registry.<host>, but not always - hence the override.
if [ "$GITLAB_HOST_VALUE" = gitlab.com ]; then
  REGISTRY="${K8S_REGISTRY:-registry.gitlab.com}"
else
  REGISTRY="${K8S_REGISTRY:-registry.$GITLAB_HOST_VALUE}"
fi
PULL_SECRET="${K8S_PULL_SECRET:-gitlab-registry}"
SECRET_NAME="${K8S_SECRET:-vm-agent-env}"
CLEVER_ORG="${CLEVER_ORG:-}"
ORG_ARGS=()
PUSH=true; WAIT=true; CONFIRMED=false

c_ok=$'\033[32m'; c_skip=$'\033[2m'; c_do=$'\033[36m'; c_err=$'\033[31m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_do"   "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok"   "  ✓ $*" "$c_off"; }
skip() { printf '%s%s%s\n' "$c_skip" "  · $*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_err"  "  ! $*" "$c_off" >&2; }
die()  { printf '%s%s%s\n' "$c_err"  "  ✗ $*" "$c_off" >&2; exit 1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

confirm() {  # $1 question
  $CONFIRMED && return 0
  [ -t 0 ] || die "$1 - re-run with --yes (nothing to ask on a non-terminal)"
  printf '%s  %s [y/N] ' "$c_do" "$1"; printf '%s' "$c_off"
  local a; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) die "cancelled" ;; esac
}

# jq 1.6 exits 0 on empty input - the filter never runs, so there is no
# failed output to report - which turns every `jq -e` guard into "yes"
# whenever the command feeding it produced nothing at all.
json_has() {  # $1.. jq args (filter last); JSON on stdin
  local doc; doc="$(cat)"
  [ -n "$doc" ] || return 1
  printf '%s' "$doc" | jq -e "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------- kubectl
# Installed into the repository's own .secrets/bin rather than anywhere on
# your PATH: this script should not decide what lands in ~/.local/bin on a
# machine it does not own. The VMs get theirs from scripts/50-kube.sh.
ensure_kubectl() {
  command -v kubectl >/dev/null 2>&1 && return 0
  local bin="$SECRETS_DIR/bin"
  if [ -x "$bin/kubectl" ]; then PATH="$bin:$PATH"; return 0; fi
  say "installing kubectl into .secrets/bin (nothing outside this repository)"
  mkdir -p "$bin"
  local ver; ver="$(curl -fsSL --max-time 30 https://dl.k8s.io/release/stable.txt 2>/dev/null)"
  [ -n "$ver" ] || die "could not resolve the current kubectl version"
  curl -fsSL --max-time 180 -o "$bin/kubectl" \
    "https://dl.k8s.io/release/$ver/bin/linux/amd64/kubectl" \
    || die "could not download kubectl $ver"
  chmod 755 "$bin/kubectl"
  PATH="$bin:$PATH"
  ok "kubectl $ver"
}

# Every kubectl call in this script goes through the fleet's own
# kubeconfig, never through whatever cluster your shell happens to point
# at. Creating a namespace on the wrong cluster is a bad way to find out
# that KUBECONFIG was set.
kube() {
  [ -s "$KUBECONFIG_PATH" ] || die "no kubeconfig - run ./cluster.sh kubeconfig"
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

# ---------------------------------------------------------------- cluster
k8s_feature_on() {
  # clever-tools colours its table, so the value is not where a plain
  # `awk '{print $NF}'` would find it.
  clever features 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -qE '^k8s[[:space:]]+beta.*[[:space:]]true[[:space:]]*$'
}

ensure_feature() {
  k8s_feature_on && { skip "clever k8s feature enabled"; return 0; }
  clever features enable k8s >/dev/null 2>&1 \
    && ok "enabled the experimental 'k8s' feature in clever-tools" \
    || die "could not enable the k8s feature - 'clever features enable k8s'"
}

cluster_json() {
  clever k8s get "$CLUSTER" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} --format json 2>/dev/null
}

cluster_status() { cluster_json | jq -r '.status // ""'; }

cmd_create() {
  hdr "cluster [$CLUSTER]"
  ensure_feature

  # A pod's credentials come from the fleet's Configuration provider -
  # there is no second place to get them - so a cluster without one has
  # nothing to hand an agent. Checked here rather than in bootstrap, three
  # steps later: a control plane bills from the moment it exists, and
  # "created, then could not be wired up" is the one failure this script
  # must not produce.
  #
  # What is missing is an *add-on*, not a VM. The cluster needs the
  # fleet's shared secrets; it has no use for a box, and no way to reach
  # an FS Bucket. `--shared-only` creates exactly that and nothing else,
  # so a fleet whose agents are all pods never creates a VM.
  if [ -z "$(addon_real_id_by_name "$CONFIG_ADDON")" ]; then
    die "no Configuration provider named $CONFIG_ADDON in this organisation.
    Pods read the fleet's shared secrets from it - the agent tokens, the
    commit key, the fleet token - so it has to exist first. It is a free
    add-on and needs no VM:

      ./agent-tokens.sh claude       store an agent credential
      ./provision.sh --shared-only   create and publish the shared config

    Then re-run this. Nothing has been created."
  fi

  local status; status="$(cluster_status)"
  if [ -n "$status" ]; then
    skip "cluster exists, status $status"
  else
    confirm "create Kubernetes cluster '$CLUSTER'? it is billed while it exists."
    say "creating cluster $CLUSTER"
    local out
    out="$(clever k8s create "$CLUSTER" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} 2>&1)"
    status="$(cluster_status)"
    if [ -z "$status" ]; then
      printf '%s\n' "$out" | tail -5 >&2
      die "could not create cluster $CLUSTER"
    fi
    ok "cluster created ($(cluster_json | jq -r '.id'))"
  fi

  if $WAIT; then
    # A control plane takes minutes. --watch inside clever-tools would do
    # this too, but it is not on the create path in every release, and a
    # poll we own reports the same thing in this script's own voice.
    local waited=0
    while [ "$status" != ACTIVE ]; do
      [ "$status" = FAILED ] && die "cluster $CLUSTER failed to deploy - check the Console"
      [ "$waited" -ge 1800 ] && die "cluster $CLUSTER is still $status after 30 minutes"
      printf '%s  %s… (%ss)\r' "$c_skip" "$status" "$waited"; printf '%s' "$c_off"
      sleep 15; waited=$(( waited + 15 ))
      status="$(cluster_status)"
    done
    printf '\033[2K'
    ok "cluster is ACTIVE"
  else
    skip "not waiting (--no-wait) - it is $status; re-run when it is ACTIVE"
    return 0
  fi

  cmd_kubeconfig
  cmd_bootstrap
  hdr "next"
  printf '  %s\n' "./cluster.sh image                 build and publish the agent image"
  printf '  %s\n' "./provision.sh --all --no-deploy   hand the kubeconfig to the VM fleet"
  printf '  %s\n' "swarm run hello 'say hi'           (once the image exists)"
}

cmd_kubeconfig() {
  hdr "kubeconfig"
  local status; status="$(cluster_status)"
  [ -n "$status" ] || die "no cluster named $CLUSTER - run ./cluster.sh create"
  [ "$status" = ACTIVE ] || die "cluster $CLUSTER is $status, not ACTIVE - the kubeconfig is not ready"

  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  local tmp; tmp="$(mktemp)"
  clever k8s get-kubeconfig "$CLUSTER" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} > "$tmp" 2>/dev/null
  # Judge by the content, not the exit status: an error page written to a
  # file is still a file, and a broken kubeconfig fails much later and much
  # more confusingly than an empty one.
  if ! grep -q '^\(apiVersion\|kind\):' "$tmp"; then
    rm -f "$tmp"
    die "clever k8s get-kubeconfig did not return a kubeconfig"
  fi
  if [ -f "$KUBECONFIG_PATH" ] && cmp -s "$tmp" "$KUBECONFIG_PATH"; then
    rm -f "$tmp"; skip ".secrets/kubeconfig.yaml already current"
  else
    mv "$tmp" "$KUBECONFIG_PATH"; chmod 600 "$KUBECONFIG_PATH"
    ok "wrote .secrets/kubeconfig.yaml"
  fi

  ensure_kubectl
  write_local_k8s_env
  local server; server="$(kube config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  if kube version --request-timeout=15s >/dev/null 2>&1; then
    ok "reachable: $server"
  else
    warn "the kubeconfig is written but $server did not answer - a freshly"
    warn "  ACTIVE cluster can take another minute to accept connections"
  fi
}

# --------------------------------------------------------------- registry
# The image lives in a GitLab project's container registry. Two different
# credentials, on purpose:
#
#   push  your own token (needs write_registry) - used here, on your
#         machine, and never leaves it.
#   pull  a project deploy token scoped to read_registry - that is the one
#         copied into the cluster, where anything that can read a secret
#         in the namespace can read it. A personal access token there
#         would hand the same reader your whole GitLab account.
gitlab_api() { glab api --hostname "$GITLAB_HOST_VALUE" "$@" 2>/dev/null; }

gitlab_user() {
  gitlab_api /user 2>/dev/null | jq -r '.username // empty'
}

url_encode_path() { printf '%s' "$1" | sed 's|/|%2F|g'; }

ensure_project() {  # sets IMAGE_PROJECT and PROJECT_ID
  need glab
  local user
  if [ -z "$IMAGE_PROJECT" ]; then
    user="$(gitlab_user)"
    [ -n "$user" ] || die "cannot read your GitLab user - is GITLAB_TOKEN set, or 'glab auth login' done?
    or name the project yourself: ./cluster.sh image --project <group>/<project>"
    IMAGE_PROJECT="$user/vm-agent-images"
  fi

  PROJECT_ID="$(gitlab_api "/projects/$(url_encode_path "$IMAGE_PROJECT")" | jq -r '.id // empty')"
  if [ -n "$PROJECT_ID" ]; then
    skip "GitLab project $IMAGE_PROJECT ($PROJECT_ID)"
    return 0
  fi

  confirm "create private GitLab project '$IMAGE_PROJECT' to hold the image?"
  local path="${IMAGE_PROJECT##*/}" group="${IMAGE_PROJECT%/*}" out
  # A project under your own namespace needs no namespace_id; one under a
  # group does, and the group has to be resolved by path first.
  if [ "$group" = "$(gitlab_user)" ]; then
    out="$(glab api --hostname "$GITLAB_HOST_VALUE" --method POST /projects \
      -f "name=$path" -f "path=$path" -f visibility=private \
      -f description="Container images for the vm-agent fleet" 2>&1)"
  else
    local gid; gid="$(gitlab_api "/groups/$(url_encode_path "$group")" | jq -r '.id // empty')"
    [ -n "$gid" ] || die "no GitLab group '$group' you can create projects in"
    out="$(glab api --hostname "$GITLAB_HOST_VALUE" --method POST /projects \
      -f "name=$path" -f "path=$path" -f "namespace_id=$gid" -f visibility=private \
      -f description="Container images for the vm-agent fleet" 2>&1)"
  fi
  PROJECT_ID="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
    printf '%s\n' "$out" | tail -5 >&2
    die "could not create $IMAGE_PROJECT"
  fi
  ok "created GitLab project $IMAGE_PROJECT ($PROJECT_ID)"
}

# A read_registry deploy token for the cluster. Kept in .secrets so a
# second run reuses it: GitLab returns the token exactly once, at creation,
# and there is no way to read it back afterwards.
ensure_deploy_token() {
  if [ -n "${K8S_REGISTRY_USER:-}" ] && [ -n "${K8S_REGISTRY_TOKEN:-}" ]; then
    skip "registry pull credentials present (.secrets/registry.env)"
    return 0
  fi
  say "creating a read_registry deploy token on $IMAGE_PROJECT"
  local out user token
  out="$(glab api --hostname "$GITLAB_HOST_VALUE" --method POST \
    "/projects/$PROJECT_ID/deploy_tokens" \
    -f "name=vm-agent-k8s" -f "username=vm-agent-k8s" \
    -f "scopes[]=read_registry" 2>&1)"
  user="$(printf '%s' "$out" | jq -r '.username // empty' 2>/dev/null)"
  token="$(printf '%s' "$out" | jq -r '.token // empty' 2>/dev/null)"
  if [ -z "$token" ]; then
    printf '%s\n' "$out" | tail -3 >&2
    warn "could not create a deploy token - falling back to GITLAB_TOKEN for pulls."
    warn "  that token can do everything your account can; prefer a deploy token"
    warn "  (Settings → Repository → Deploy tokens, scope read_registry) and put it"
    warn "  in .secrets/registry.env as K8S_REGISTRY_USER / K8S_REGISTRY_TOKEN."
    [ -n "${GITLAB_TOKEN:-}" ] || die "no GITLAB_TOKEN either - nothing to pull the image with"
    K8S_REGISTRY_USER="$(gitlab_user)"
    K8S_REGISTRY_TOKEN="$GITLAB_TOKEN"
    return 0
  fi
  K8S_REGISTRY_USER="$user"; K8S_REGISTRY_TOKEN="$token"
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  {
    echo "# Generated by cluster.sh - gitignored, do not commit."
    echo "# A read_registry deploy token on $IMAGE_PROJECT. GitLab shows a"
    echo "# deploy token once, at creation; this is the only copy."
    printf 'export K8S_REGISTRY_USER=%s\n' "\"$user\""
    printf 'export K8S_REGISTRY_TOKEN=%s\n' "\"$token\""
  } > "$REGISTRY_ENV"
  chmod 600 "$REGISTRY_ENV"
  ok "deploy token created and saved to .secrets/registry.env"
}

image_ref() { printf '%s/%s/%s:%s' "$REGISTRY" "$IMAGE_PROJECT" "$IMAGE_NAME" "$IMAGE_TAG"; }

cmd_image() {
  hdr "agent image"
  need jq
  local builder=""
  for b in docker podman nerdctl; do command -v "$b" >/dev/null && { builder="$b"; break; }; done
  [ -n "$builder" ] || die "no container builder found (docker, podman or nerdctl)
    the image can also be built on a VM that has --dockerd; see the README"

  ensure_project
  local ref; ref="$(image_ref)"

  say "building $ref with $builder (context: the repository root)"
  "$builder" build -f "$ROOT/k8s/Dockerfile" -t "$ref" "$ROOT" \
    || die "image build failed"
  ok "built $ref"

  if ! $PUSH; then
    skip "not pushing (--no-push)"
    return 0
  fi

  [ -n "${GITLAB_TOKEN:-}" ] || die "GITLAB_TOKEN is not set - it is what pushes to the registry
    ./agent-tokens.sh set GITLAB_TOKEN"
  say "logging in to $REGISTRY"
  printf '%s' "$GITLAB_TOKEN" | "$builder" login "$REGISTRY" \
    --username "$(gitlab_user)" --password-stdin >/dev/null 2>&1 \
    || die "could not log in to $REGISTRY - does GITLAB_TOKEN have write_registry?"
  "$builder" push "$ref" || die "could not push $ref"
  ok "pushed $ref"

  # The cluster has to be able to pull it, and the fleet has to know what
  # to spawn. Both are written where they are read from, not announced.
  ensure_deploy_token
  record_setting K8S_IMAGE_PROJECT "$IMAGE_PROJECT"
  record_setting K8S_IMAGE "$ref"
  K8S_IMAGE="$ref"; write_local_k8s_env
  if [ -s "$KUBECONFIG_PATH" ]; then
    ensure_kubectl
    ensure_pull_secret
  else
    skip "no kubeconfig yet - run ./cluster.sh bootstrap once the cluster exists"
  fi
  hdr "next"
  printf '  %s\n' "./provision.sh --all --no-deploy   publish K8S_IMAGE to the fleet"
}

# So `swarm` works from this machine too, not just from a VM where the
# shared Configuration provider supplies all of this. Same idea as
# provision.sh's .secrets/fleet.env, for the same reason.
write_local_k8s_env() {
  local f="$SECRETS_DIR/k8s.env" tmp
  [ -s "$KUBECONFIG_PATH" ] || return 0
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  tmp="$(mktemp)"
  {
    echo "# Generated by cluster.sh - gitignored, do not commit."
    printf 'export KUBECONFIG=%s\n' "\"$KUBECONFIG_PATH\""
    printf 'export VM_AGENT_K8S_NAMESPACE=%s\n' "\"$NAMESPACE\""
    [ -n "${K8S_IMAGE:-}" ] && printf 'export VM_AGENT_K8S_IMAGE=%s\n' "\"$K8S_IMAGE\""
    printf 'export K8S_AGENT_CPU=%s\n'    "\"${K8S_AGENT_CPU:-1}\""
    printf 'export K8S_AGENT_MEMORY=%s\n' "\"${K8S_AGENT_MEMORY:-2Gi}\""
    printf 'export PATH=%s\n' "\"$SECRETS_DIR/bin:\$PATH\""
  } > "$tmp"
  if [ -f "$f" ] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"; skip ".secrets/k8s.env already current"
  else
    mv "$tmp" "$f"; chmod 600 "$f"
    ok "wrote .secrets/k8s.env for the local swarm client"
  fi
}

# fleet.conf is where the fleet's non-secret settings live and where
# provision.sh reads them from, so a value this script derives belongs
# there rather than in a message telling you to type it in yourself.
record_setting() {  # $1 var, $2 value
  local var="$1" value="$2" conf="$ROOT/fleet.conf" line
  line=": \"\${$var:=$value}\"  # written by cluster.sh"
  if [ ! -f "$conf" ]; then
    skip "no fleet.conf - add this yourself: $line"
    return 0
  fi
  if grep -qE "^[[:space:]]*:? *\"?\\\$\\{$var:=" "$conf"; then
    if grep -qxF "$line" "$conf"; then
      skip "fleet.conf already has $var"
      return 0
    fi
    # Rewrite in place rather than appending: two definitions of the same
    # variable in a sourced file means the first one wins, silently.
    local tmp; tmp="$(mktemp)"
    sed -E "s|^[[:space:]]*:? *\"?\\\$\\{$var:=.*|$line|" "$conf" > "$tmp" && mv "$tmp" "$conf"
    ok "fleet.conf: $var updated"
  else
    printf '%s\n' "$line" >> "$conf"
    ok "fleet.conf: $var recorded"
  fi
}

# --------------------------------------------------------------- bootstrap
ensure_namespace() {
  if kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    skip "namespace $NAMESPACE exists"
  else
    kube create namespace "$NAMESPACE" >/dev/null 2>&1 \
      && ok "namespace $NAMESPACE created" || die "could not create namespace $NAMESPACE"
  fi
}

ensure_pull_secret() {
  [ -n "${K8S_REGISTRY_USER:-}" ] && [ -n "${K8S_REGISTRY_TOKEN:-}" ] \
    || { skip "no registry pull credentials yet - run ./cluster.sh image"; return 0; }
  ensure_namespace
  # Recreated rather than compared: a docker-registry secret is an opaque
  # blob of JSON and "is it already right" costs more than rewriting it.
  kube -n "$NAMESPACE" delete secret "$PULL_SECRET" >/dev/null 2>&1
  kube -n "$NAMESPACE" create secret docker-registry "$PULL_SECRET" \
    --docker-server="$REGISTRY" \
    --docker-username="$K8S_REGISTRY_USER" \
    --docker-password="$K8S_REGISTRY_TOKEN" >/dev/null 2>&1 \
    && ok "pull secret $PULL_SECRET set for $REGISTRY" \
    || die "could not create the registry pull secret"
}

# clever-tools 4.5 has no `config-provider` subcommand, but its `curl`
# passes our credentials to the public API, which does. Same call
# provision.sh makes - one source of truth for what the fleet knows.
cp_read() {
  clever curl -s \
    "https://api.clever-cloud.com/v4/addon-providers/config-provider/addons/$1/env" 2>/dev/null
}

addon_real_id_by_name() {
  clever addon list ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} --format json 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name==$n) | .realId' | head -1
}
addon_id_by_name() {
  clever addon list ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} --format json 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name==$n) | .addonId' | head -1
}

# The pods get exactly what the VMs get, from exactly where the VMs get it
# - the shared Configuration provider - plus the Cellar credentials, which
# a VM receives from its linked add-on and a pod has no add-on to receive.
#
# A pod that authenticates from a second, hand-maintained list of secrets
# is a pod that stops matching the fleet the first time a token rotates.
cmd_secrets() {
  hdr "agent secrets"
  need jq; ensure_kubectl; ensure_namespace

  local config_id env_json
  config_id="$(addon_real_id_by_name "$CONFIG_ADDON")"
  [ -n "$config_id" ] || die "no Configuration provider named $CONFIG_ADDON.
    Create it with: ./provision.sh --shared-only   (no VM required)"
  env_json="$(cp_read "$config_id")"
  printf '%s' "$env_json" | json_has 'length > 0' \
    || die "the shared configuration $CONFIG_ADDON is empty or unreadable"

  # Cellar, so `cellar` works in a pod and the entrypoint can push ~/out
  # somewhere that outlives it.
  local cellar_id cellar_json
  cellar_id="$(addon_id_by_name "$CELLAR_ADDON")"
  if [ -n "$cellar_id" ]; then
    cellar_json="$(clever addon env "$cellar_id" --format json 2>/dev/null)"
  else
    cellar_json='{}'
    skip "no Cellar add-on named $CELLAR_ADDON - pods will have nowhere to leave results"
  fi

  # Written through a file, not through `kubectl create secret --from-literal`:
  # literals land in this machine's process list, and one of them is the
  # fleet's commit key.
  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: $SECRET_NAME"
    echo "  labels:"
    echo "    vm-agent/managed: \"true\""
    echo "type: Opaque"
    echo "data:"
    # VM_AGENT_KUBECONFIG_B64 is deliberately dropped: a pod that can spawn
    # pods is a fleet that can fork itself by accident, and nothing in the
    # pod workflow needs it.
    printf '%s' "$env_json" | jq -r '
      .[]
      | select(.name != "VM_AGENT_KUBECONFIG_B64")
      | "  \(.name): \(.value | @base64)"'
    printf '%s' "$cellar_json" | jq -r '
      to_entries[]
      | select(.key | startswith("CELLAR_ADDON_"))
      | "  \(.key): \(.value | @base64)"'
  } > "$tmp"

  if kube -n "$NAMESPACE" apply -f "$tmp" >/dev/null 2>&1; then
    ok "secret $SECRET_NAME synced ($(grep -c '^  [A-Z]' "$tmp") variables)"
  else
    rm -f "$tmp"; die "could not write the secret $SECRET_NAME"
  fi
  rm -f "$tmp"

  printf '%s' "$env_json" | json_has '.[] | select(.name=="VM_AGENT_FLEET_TOKEN")' \
    || warn "no VM_AGENT_FLEET_TOKEN in the shared config - a pod's endpoint will
  fail closed and swarm will not be able to talk to it"
}

cmd_bootstrap() {
  hdr "namespace [$NAMESPACE]"
  need jq; ensure_kubectl
  ensure_namespace
  ensure_pull_secret
  cmd_secrets
  write_local_k8s_env
}

cmd_storage() {
  hdr "persistent storage"
  local status; status="$(cluster_status)"
  [ "$status" = ACTIVE ] || die "cluster $CLUSTER is ${status:-missing}, not ACTIVE"
  ensure_kubectl
  if kube get storageclass -o name 2>/dev/null | grep -q ceph; then
    skip "a Ceph storage class is already present"
    kube get storageclass
    return 0
  fi
  confirm "enable persistent storage (Ceph CSI) on '$CLUSTER'? it is billed per volume."
  clever k8s add-persistent-storage "$CLUSTER" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} >/dev/null 2>&1 \
    && ok "persistent storage requested - the storage class appears in a minute or two" \
    || die "could not enable persistent storage"
}

cmd_status() {
  hdr "cluster [$CLUSTER]"
  local json; json="$(cluster_json)"
  if [ -z "$json" ]; then
    skip "no cluster named $CLUSTER in this organisation"
    return 0
  fi
  printf '%s' "$json" | jq -r '"  \(.name)  \(.id)  status \(.status)  version \(.version // "?")"'
  [ -s "$KUBECONFIG_PATH" ] || { skip "no local kubeconfig - ./cluster.sh kubeconfig"; return 0; }
  ensure_kubectl

  hdr "nodes"
  kube get nodes -o wide 2>/dev/null | sed 's/^/  /' || warn "cluster unreachable"

  hdr "namespace [$NAMESPACE]"
  if kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    kube -n "$NAMESPACE" get pods -l vm-agent/managed=true 2>/dev/null | sed 's/^/  /'
  else
    skip "namespace $NAMESPACE does not exist - ./cluster.sh bootstrap"
  fi
}

cmd_doctor() {
  hdr "doctor"
  local bad=0
  step() {  # $1 label, $2.. command
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label"; bad=$(( bad + 1 )); fi
  }
  cluster_is_active() { [ "$(cluster_status)" = ACTIVE ]; }
  image_is_recorded() { [ -n "${K8S_IMAGE:-}" ]; }

  step "clever-tools is logged in"        clever profile
  step "the k8s feature is enabled"       k8s_feature_on
  step "cluster $CLUSTER is ACTIVE"       cluster_is_active
  step "a kubeconfig exists"              test -s "$KUBECONFIG_PATH"
  if [ ! -s "$KUBECONFIG_PATH" ]; then
    # Everything below needs a cluster to ask. Downloading kubectl to find
    # out there is nothing to point it at is 50MB of wasted certainty.
    hdr "no kubeconfig - skipping the cluster-side checks"
    printf '  %s\n' "./cluster.sh create   then   ./cluster.sh image"
    exit 1
  fi
  ensure_kubectl
  step "the cluster answers"              env KUBECONFIG="$KUBECONFIG_PATH" kubectl version --request-timeout=15s
  step "namespace $NAMESPACE exists"      env KUBECONFIG="$KUBECONFIG_PATH" kubectl get namespace "$NAMESPACE"
  step "pull secret $PULL_SECRET exists"  env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$NAMESPACE" get secret "$PULL_SECRET"
  step "agent secret $SECRET_NAME exists" env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$NAMESPACE" get secret "$SECRET_NAME"
  step "the agent image is recorded"      image_is_recorded
  if [ "$bad" -eq 0 ]; then
    hdr "ready"
    printf '  %s\n' "swarm run hello 'reply with the word ok' --wait"
  else
    hdr "$bad check(s) failed"
    printf '  %s\n' "./cluster.sh create   then   ./cluster.sh image   then   ./cluster.sh bootstrap"
    exit 1
  fi
}

cmd_destroy() {
  hdr "destroying [$CLUSTER]"
  local status; status="$(cluster_status)"
  [ -n "$status" ] || { skip "no cluster named $CLUSTER"; return 0; }
  confirm "delete cluster '$CLUSTER' and everything running on it?"
  clever k8s delete "$CLUSTER" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"} --yes >/dev/null 2>&1 \
    && ok "cluster deleted" || die "could not delete $CLUSTER"
  rm -f "$KUBECONFIG_PATH" && skip "removed .secrets/kubeconfig.yaml"
  warn "the VMs still carry VM_AGENT_KUBECONFIG_B64. Clear it with:"
  warn "  ./provision.sh --all --no-deploy --forget VM_AGENT_KUBECONFIG_B64"
  warn "The GitLab project and its images are untouched."
}

print_header_comment() {
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}
usage() { print_header_comment; exit "${1:-0}"; }

# ------------------------------------------------------------------ main
need clever; need jq; need curl

ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --org|--owner) CLEVER_ORG="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --project)   IMAGE_PROJECT="$2"; shift 2 ;;
    --tag)       IMAGE_TAG="$2"; shift 2 ;;
    --no-push)   PUSH=false; shift ;;
    --no-wait)   WAIT=false; shift ;;
    --yes|-y)    CONFIRMED=true; shift ;;
    -h|--help)   usage ;;
    -*)          die "unknown option: $1" ;;
    *)           [ -n "$ACTION" ] && die "one action at a time (got '$ACTION' and '$1')"
                 ACTION="$1"; shift ;;
  esac
done

clever profile >/dev/null 2>&1 || die "not logged in - run 'clever login' first"

# Same check provision.sh makes, for the same reason: clever accepts an
# organisation name, but a name that matches nothing is only reported once
# it has already created something somewhere else.
if [ -n "$CLEVER_ORG" ]; then
  orgs="$(clever curl -s https://api.clever-cloud.com/v2/organisations 2>/dev/null)"
  if [ -z "$orgs" ]; then
    say "could not list your organisations - passing --org through unchecked"
  else
    match="$(printf '%s' "$orgs" | jq -r --arg o "$CLEVER_ORG" \
      '[.[] | select(.id == $o or .name == $o)] | if length == 1 then .[0].id else empty end')"
    [ -n "$match" ] || {
      printf '%s\n' "$c_err  ✗ no single organisation matches '$CLEVER_ORG'. You belong to:$c_off" >&2
      printf '%s' "$orgs" | jq -r '.[] | "      \(.id)  \(.name)"' >&2
      exit 1
    }
    CLEVER_ORG="$match"
  fi
  ORG_ARGS=(--org "$CLEVER_ORG")
fi

case "${ACTION:-status}" in
  create)     cmd_create ;;
  image)      cmd_image ;;
  bootstrap)  cmd_bootstrap ;;
  secrets)    cmd_secrets ;;
  kubeconfig) cmd_kubeconfig ;;
  storage)    cmd_storage ;;
  status)     cmd_status ;;
  doctor)     cmd_doctor ;;
  destroy)    cmd_destroy ;;
  *)          die "unknown action: $ACTION (try --help)" ;;
esac
