#!/usr/bin/env bash
# Idempotent provisioner for a fleet of vm-agent boxes on Clever Cloud.
#
# Every step checks the desired state before touching anything, so running
# this twice is a no-op and running it after a partial failure resumes
# where it stopped. Each VM gets its own application, its own FS Bucket and
# (by default) its own Cellar add-on; they share one git-commit SSH key so
# the public key only has to be registered on the forges once.
#
#   ./provision.sh web-agent                 create or update one VM
#   ./provision.sh agent --count 4           agent-1 .. agent-4
#   ./provision.sh --all                     re-apply to every VM in vms.txt
#   ./provision.sh --list                    show the fleet
#   ./provision.sh --destroy agent-3 --yes   tear one down
set -uo pipefail

# ---------------------------------------------------------------- config
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$ROOT/.secrets"
FLEET_FILE="$ROOT/vms.txt"
FLAVOR="M"
REGION="par"
KEY_PATH="$SECRETS_DIR/id_ed25519"
PER_VM_KEY=false
DEPLOY=true
COUNT=1
CELLAR_SHARED=""
GIT_NAME="${GIT_USER_NAME:-vm-agent}"
GIT_EMAIL="${GIT_USER_EMAIL:-vm-agent@clever-cloud.local}"
SIGN_COMMITS="${GIT_SIGN_COMMITS:-false}"
GITLAB_HOST_VALUE="${GITLAB_HOST:-gitlab.com}"

# .secrets/tokens.env is gitignored; export GH_TOKEN / GITLAB_TOKEN there.
[ -f "$SECRETS_DIR/tokens.env" ] && . "$SECRETS_DIR/tokens.env"
GH_TOKEN="${GH_TOKEN:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

# ---------------------------------------------------------------- output
c_ok=$'\033[32m'; c_skip=$'\033[2m'; c_do=$'\033[36m'; c_err=$'\033[31m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_do"   "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok"   "  ✓ $*" "$c_off"; }
skip() { printf '%s%s%s\n' "$c_skip" "  · $*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err"  "  ✗ $*" "$c_off" >&2; exit 1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------- utilities
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

app_id_by_name() {
  clever applications list --format json 2>/dev/null \
    | jq -r --arg n "$1" '.[].applications[]? | select(.name==$n) | .app_id' | head -1
}

addon_id_by_name() {
  clever addon list --format json 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name==$n) | .addonId' | head -1
}

is_linked_locally() {
  [ -f "$ROOT/.clever.json" ] || return 1
  jq -e --arg id "$1" '.apps[]? | select(.app_id==$id)' "$ROOT/.clever.json" >/dev/null 2>&1
}

is_addon_linked() {
  clever service --only-addons --format json --alias "$1" 2>/dev/null \
    | jq -e --arg id "$2" '.addons[]? | select(.id==$id and .isLinked==true)' >/dev/null 2>&1
}

env_value() {
  clever env --format json --alias "$1" 2>/dev/null \
    | jq -r --arg k "$2" '.env[]? | select(.name==$k) | .value' | head -1
}

# Set an env var only when its current value differs, so re-runs stay quiet
# and do not trigger pointless restarts.
ensure_env() {
  local alias="$1" key="$2" want="$3"
  if [ "$(env_value "$alias" "$key")" = "$want" ]; then
    skip "env $key already set"
  else
    clever env set "$key" "$want" --alias "$alias" >/dev/null 2>&1 \
      && ok "env $key set" || die "could not set $key"
  fi
}

# A token we do not have locally must never clobber one already stored on
# the application: an empty local value means "leave whatever is there".
ensure_env_secret() {
  local alias="$1" key="$2" want="$3" current
  current="$(env_value "$alias" "$key")"
  if [ -z "$want" ] && [ -n "$current" ]; then
    skip "env $key kept (no local value to apply)"
  else
    ensure_env "$alias" "$key" "$want"
  fi
}

# ------------------------------------------------------------------ key
ensure_key() {
  local path="$1"
  mkdir -p "$(dirname "$path")"; chmod 700 "$SECRETS_DIR"
  if [ -f "$path" ]; then
    skip "commit key present ($(ssh-keygen -lf "$path.pub" | awk '{print $2}'))"
  else
    ssh-keygen -t ed25519 -C "$(basename "$path" | sed 's/^id_ed25519$/vm-agent/')@clever-cloud" \
      -f "$path" -N "" -q
    ok "generated commit key $(ssh-keygen -lf "$path.pub" | awk '{print $2}')"
  fi
}

# -------------------------------------------------------------- one VM
provision_one() {
  local name="$1"
  hdr "[$name]"

  # --- application ------------------------------------------------------
  local app_id
  app_id="$(app_id_by_name "$name")"
  if [ -z "$app_id" ]; then
    say "creating application (linux, $REGION)"
    clever create --type linux "$name" --region "$REGION" --alias "$name" >/dev/null 2>&1 \
      || die "could not create application $name"
    app_id="$(app_id_by_name "$name")"
    [ -n "$app_id" ] || die "application $name was created but cannot be found"
    ok "application created: $app_id"
  else
    skip "application exists: $app_id"
    if ! is_linked_locally "$app_id"; then
      clever link "$app_id" --alias "$name" >/dev/null 2>&1 && ok "linked to this repo"
    else
      skip "already linked to this repo"
    fi
  fi

  # --- scaling ----------------------------------------------------------
  local current_flavor
  current_flavor="$(clever status --alias "$name" 2>/dev/null | sed -n 's/^ *Sizes: *//p' | head -1)"
  if [ "$current_flavor" = "$FLAVOR" ]; then
    skip "flavor already $FLAVOR"
  else
    clever scale --flavor "$FLAVOR" --alias "$name" >/dev/null 2>&1 && ok "scaled to $FLAVOR"
  fi

  # --- Cellar add-on ----------------------------------------------------
  local cellar_name cellar_id
  cellar_name="${CELLAR_SHARED:-$name-cellar}"
  cellar_id="$(addon_id_by_name "$cellar_name")"
  if [ -z "$cellar_id" ]; then
    say "creating Cellar add-on $cellar_name"
    clever addon create cellar-addon "$cellar_name" --plan S --region "$REGION" \
      --format json >/dev/null 2>&1 || die "could not create Cellar add-on"
    cellar_id="$(addon_id_by_name "$cellar_name")"
    ok "Cellar add-on created: $cellar_id"
  else
    skip "Cellar add-on exists: $cellar_id"
  fi
  if is_addon_linked "$name" "$cellar_id"; then
    skip "Cellar linked"
  else
    clever service link-addon "$cellar_id" --alias "$name" >/dev/null 2>&1 && ok "Cellar linked"
  fi

  # --- FS Bucket add-on -------------------------------------------------
  local fs_name fs_id bucket_host
  fs_name="$name-fs"
  fs_id="$(addon_id_by_name "$fs_name")"
  if [ -z "$fs_id" ]; then
    say "creating FS Bucket add-on $fs_name"
    clever addon create fs-bucket "$fs_name" --plan s --region "$REGION" \
      --format json >/dev/null 2>&1 || die "could not create FS Bucket add-on"
    fs_id="$(addon_id_by_name "$fs_name")"
    ok "FS Bucket add-on created: $fs_id"
  else
    skip "FS Bucket add-on exists: $fs_id"
  fi
  if is_addon_linked "$name" "$fs_id"; then
    skip "FS Bucket linked"
  else
    clever service link-addon "$fs_id" --alias "$name" >/dev/null 2>&1 && ok "FS Bucket linked"
  fi
  bucket_host="$(clever addon env "$fs_id" --format json 2>/dev/null | jq -r '.BUCKET_HOST // ""')"
  [ -n "$bucket_host" ] || die "could not read BUCKET_HOST for $fs_name"

  # --- commit key -------------------------------------------------------
  local key_path="$KEY_PATH"
  $PER_VM_KEY && key_path="$SECRETS_DIR/$name/id_ed25519"
  ensure_key "$key_path"

  # --- environment ------------------------------------------------------
  # CC_FS_BUCKET paths are resolved relative to APP_HOME, hence "/persistent".
  ensure_env "$name" CC_FS_BUCKET        "/persistent:$bucket_host"
  ensure_env "$name" VM_AGENT_SSH_KEY_B64 "$(base64 -w0 < "$key_path")"
  ensure_env "$name" CELLAR_BUCKET       "$name-files"
  ensure_env "$name" GIT_USER_NAME       "$GIT_NAME"
  ensure_env "$name" GIT_USER_EMAIL      "$GIT_EMAIL"
  ensure_env "$name" GIT_SIGN_COMMITS    "$SIGN_COMMITS"
  ensure_env "$name" GITLAB_HOST         "$GITLAB_HOST_VALUE"
  ensure_env_secret "$name" GH_TOKEN     "$GH_TOKEN"
  ensure_env_secret "$name" GITLAB_TOKEN "$GITLAB_TOKEN"
  # Lets an agent inside the box know which VM it is.
  ensure_env "$name" VM_AGENT_NAME       "$name"

  # --- fleet registry ---------------------------------------------------
  touch "$FLEET_FILE"
  grep -qxF "$name" "$FLEET_FILE" || { echo "$name" >> "$FLEET_FILE"; ok "added to vms.txt"; }

  # --- deploy -----------------------------------------------------------
  if $DEPLOY; then
    say "deploying"
    local out
    out="$(clever deploy --alias "$name" 2>&1)"
    if printf '%s' "$out" | grep -qiE 'up.to.date|already deployed|nothing to (push|commit)'; then
      skip "already at this commit - restarting to apply env changes"
      clever restart --alias "$name" >/dev/null 2>&1 && ok "restarted"
    elif printf '%s' "$out" | grep -qi 'Deployment failed'; then
      printf '%s\n' "$out" | tail -20
      die "deployment failed for $name"
    else
      ok "deployed"
    fi
  else
    skip "deploy skipped (--no-deploy)"
  fi

  printf '  %s\n' "https://app-${app_id#app_}.cleverapps.io/status"
}

# --------------------------------------------------------------- actions
do_list() {
  hdr "fleet"
  [ -s "$FLEET_FILE" ] || { skip "no VMs provisioned yet"; return; }
  printf '  %-20s %-10s %-38s %s\n' NAME STATE APP_ID FLAVOR
  while read -r name; do
    [ -n "$name" ] || continue
    local id state flavor
    id="$(app_id_by_name "$name")"
    if [ -z "$id" ]; then
      printf '  %-20s %-10s %s\n' "$name" "MISSING" "-"
      continue
    fi
    state="$(clever status --alias "$name" 2>/dev/null | sed -n '1s/.*: *//p' | tr -d '\033[]0-9;m')"
    flavor="$(clever status --alias "$name" 2>/dev/null | sed -n 's/^ *Sizes: *//p' | head -1)"
    printf '  %-20s %-10s %-38s %s\n' "$name" "${state:-?}" "$id" "${flavor:-?}"
  done < "$FLEET_FILE"
}

do_destroy() {
  local name="$1" confirmed="$2"
  $confirmed || die "refusing to destroy $name without --yes"
  hdr "destroying [$name]"
  for addon in "$name-cellar" "$name-fs"; do
    local id; id="$(addon_id_by_name "$addon")"
    if [ -n "$id" ]; then
      clever addon delete "$id" --yes >/dev/null 2>&1 && ok "deleted add-on $addon" \
        || say "could not delete add-on $addon (delete it from the Console)"
    else
      skip "add-on $addon does not exist"
    fi
  done
  if [ -n "$(app_id_by_name "$name")" ]; then
    clever delete --alias "$name" --yes >/dev/null 2>&1 && ok "deleted application $name"
  else
    skip "application $name does not exist"
  fi
  [ -f "$FLEET_FILE" ] && { grep -vxF "$name" "$FLEET_FILE" > "$FLEET_FILE.tmp" || true; mv "$FLEET_FILE.tmp" "$FLEET_FILE"; }
}

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ------------------------------------------------------------------ main
need clever; need jq; need ssh-keygen; need base64

NAMES=(); ACTION="provision"; CONFIRMED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --flavor)   FLAVOR="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    --count)    COUNT="$2"; shift 2 ;;
    --cellar)   CELLAR_SHARED="$2"; shift 2 ;;
    --key)      KEY_PATH="$2"; shift 2 ;;
    --per-vm-key) PER_VM_KEY=true; shift ;;
    --no-deploy)  DEPLOY=false; shift ;;
    --all)      ACTION="all"; shift ;;
    --list)     ACTION="list"; shift ;;
    --destroy)  ACTION="destroy"; NAMES+=("$2"); shift 2 ;;
    --yes|-y)   CONFIRMED=true; shift ;;
    -h|--help)  usage ;;
    -*)         die "unknown option: $1" ;;
    *)          NAMES+=("$1"); shift ;;
  esac
done

clever profile >/dev/null 2>&1 || die "not logged in - run 'clever login' first"

case "$ACTION" in
  list)    do_list ;;
  destroy) do_destroy "${NAMES[0]}" "$CONFIRMED" ;;
  all)
    [ -s "$FLEET_FILE" ] || die "vms.txt is empty - provision a VM first"
    while read -r n; do [ -n "$n" ] && provision_one "$n"; done < "$FLEET_FILE"
    ;;
  provision)
    [ "${#NAMES[@]}" -gt 0 ] || usage 1
    for base in "${NAMES[@]}"; do
      if [ "$COUNT" -gt 1 ]; then
        for i in $(seq 1 "$COUNT"); do provision_one "$base-$i"; done
      else
        provision_one "$base"
      fi
    done
    ;;
esac

if [ "$ACTION" = "provision" ] || [ "$ACTION" = "all" ]; then
  hdr "commit key to register on your forges"
  cat "${KEY_PATH}.pub"
  printf '\n  GitHub: https://github.com/settings/keys\n'
  printf '  GitLab: glab api --method POST /user/keys -f "title=vm-agent" -f "key=$(cat %s.pub)" -f usage_type=auth_and_signing\n' "$KEY_PATH"
fi
