#!/usr/bin/env bash
# Idempotent provisioner for a fleet of vm-agent boxes on Clever Cloud.
#
# Every step checks the desired state before touching anything, so running
# this twice is a no-op and running it after a partial failure resumes
# where it stopped. Each VM gets its own application, its own FS Bucket and
# (by default) its own Cellar add-on. Everything the whole fleet shares -
# the git-commit key, the forge tokens, the commit identity - lives in one
# free Configuration provider add-on linked to every app, so a secret is
# rotated in a single place and the public key is registered on the forges
# only once.
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
CONFIG_ADDON="vm-agent-config"
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

addon_real_id_by_name() {
  clever addon list --format json 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name==$n) | .realId' | head -1
}

# clever-tools 4.5 has no `config-provider` subcommand, but its `curl`
# passes our credentials through to the public API, which does.
cp_env_url() {
  printf 'https://api.clever-cloud.com/v4/addon-providers/config-provider/addons/%s/env' "$1"
}
cp_read()  { clever curl -s "$(cp_env_url "$1")" 2>/dev/null; }
cp_write() {
  clever curl -s -X PUT "$(cp_env_url "$1")" \
    -H "Content-Type: application/json" -d "$2" 2>/dev/null
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

# ---------------------------------------------------- shared config
# Creates the Configuration provider once and returns its real id.
ensure_config_provider() {
  local id out
  id="$(addon_real_id_by_name "$CONFIG_ADDON")"
  if [ -z "$id" ]; then
    say "creating Configuration provider $CONFIG_ADDON" >&2
    out="$(clever addon create config-provider "$CONFIG_ADDON" --plan std \
      --region "$REGION" --format json 2>&1)"
    id="$(addon_real_id_by_name "$CONFIG_ADDON")"
    if [ -z "$id" ]; then
      printf '%s\n' "$out" | tail -5 >&2
      die "could not create Configuration provider $CONFIG_ADDON"
    fi
    ok "Configuration provider created: $id" >&2
  else
    skip "Configuration provider exists: $id" >&2
  fi
  printf '%s' "$id"
}

# Writes the fleet-wide variables. A token we do not hold locally is read
# back from the provider rather than blanked, so `--all` without secrets in
# the shell is safe. Changing a value restarts every linked app.
sync_shared_config() {
  local id="$1" current desired gh gl
  current="$(cp_read "$id")"
  [ -n "$current" ] || current='[]'

  gh="$GH_TOKEN"; gl="$GITLAB_TOKEN"
  [ -z "$gh" ] && gh="$(printf '%s' "$current" | jq -r '.[]? | select(.name=="GH_TOKEN") | .value' | head -1)"
  [ -z "$gl" ] && gl="$(printf '%s' "$current" | jq -r '.[]? | select(.name=="GITLAB_TOKEN") | .value' | head -1)"

  desired="$(jq -n \
    --arg key   "$(base64 -w0 < "$KEY_PATH")" \
    --arg gh    "$gh" \
    --arg gl    "$gl" \
    --arg host  "$GITLAB_HOST_VALUE" \
    --arg gname "$GIT_NAME" \
    --arg gmail "$GIT_EMAIL" \
    --arg sign  "$SIGN_COMMITS" \
    '[{name:"VM_AGENT_SSH_KEY_B64",value:$key},
      {name:"GH_TOKEN",value:$gh},
      {name:"GITLAB_TOKEN",value:$gl},
      {name:"GITLAB_HOST",value:$host},
      {name:"GIT_USER_NAME",value:$gname},
      {name:"GIT_USER_EMAIL",value:$gmail},
      {name:"GIT_SIGN_COMMITS",value:$sign}]')"

  # Per-VM keys cannot live in a shared provider.
  $PER_VM_KEY && desired="$(printf '%s' "$desired" | jq 'map(select(.name!="VM_AGENT_SSH_KEY_B64"))')"

  if [ "$(printf '%s' "$current" | jq -S 'sort_by(.name)')" = "$(printf '%s' "$desired" | jq -S 'sort_by(.name)')" ]; then
    skip "shared config already up to date"
  else
    cp_write "$id" "$desired" >/dev/null
    if [ "$(cp_read "$id" | jq -S 'sort_by(.name)')" = "$(printf '%s' "$desired" | jq -S 'sort_by(.name)')" ]; then
      ok "shared config written ($(printf '%s' "$desired" | jq 'length') variables)"
    else
      die "could not write the shared configuration"
    fi
  fi
}

# Values set directly on an application shadow the provider, so anything
# the provider now owns must be cleared from the app.
prune_shadowing_env() {
  local alias="$1" key
  for key in VM_AGENT_SSH_KEY_B64 GH_TOKEN GITLAB_TOKEN GITLAB_HOST \
             GIT_USER_NAME GIT_USER_EMAIL GIT_SIGN_COMMITS; do
    $PER_VM_KEY && [ "$key" = VM_AGENT_SSH_KEY_B64 ] && continue
    if clever env --format json --alias "$alias" 2>/dev/null \
        | jq -e --arg k "$key" '.env[]? | select(.name==$k)' >/dev/null 2>&1; then
      clever env rm "$key" --alias "$alias" >/dev/null 2>&1 \
        && ok "removed $key from app env (now provided by $CONFIG_ADDON)"
    fi
  done
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
  local name="$1" config_id="$2"
  hdr "[$name]"

  # --- application ------------------------------------------------------
  # Throughout: judge success by the resulting state, not by exit codes.
  # `clever create` in particular returns non-zero on a successful create.
  local app_id out
  app_id="$(app_id_by_name "$name")"
  if [ -z "$app_id" ]; then
    say "creating application (linux, $REGION)"
    out="$(clever create --type linux "$name" --region "$REGION" --alias "$name" 2>&1)"
    app_id="$(app_id_by_name "$name")"
    if [ -z "$app_id" ]; then
      printf '%s\n' "$out" | tail -5
      die "could not create application $name"
    fi
    ok "application created: $app_id"
  else
    skip "application exists: $app_id"
  fi

  if is_linked_locally "$app_id"; then
    skip "already linked to this repo"
  else
    clever link "$app_id" --alias "$name" >/dev/null 2>&1
    is_linked_locally "$app_id" && ok "linked to this repo" \
      || die "could not link $name to this repo"
  fi

  # --- scaling ----------------------------------------------------------
  local current_flavor
  current_flavor="$(clever status --alias "$name" --format json 2>/dev/null \
    | jq -r '.instances[0].flavor // ""')"
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
    out="$(clever addon create cellar-addon "$cellar_name" --plan S --region "$REGION" --format json 2>&1)"
    cellar_id="$(addon_id_by_name "$cellar_name")"
    if [ -z "$cellar_id" ]; then
      printf '%s\n' "$out" | tail -5
      die "could not create Cellar add-on $cellar_name"
    fi
    ok "Cellar add-on created: $cellar_id"
  else
    skip "Cellar add-on exists: $cellar_id"
  fi
  if is_addon_linked "$name" "$cellar_id"; then
    skip "Cellar linked"
  else
    clever service link-addon "$cellar_id" --alias "$name" >/dev/null 2>&1
    is_addon_linked "$name" "$cellar_id" && ok "Cellar linked" || die "could not link Cellar"
  fi

  # --- FS Bucket add-on -------------------------------------------------
  local fs_name fs_id bucket_host
  fs_name="$name-fs"
  fs_id="$(addon_id_by_name "$fs_name")"
  if [ -z "$fs_id" ]; then
    say "creating FS Bucket add-on $fs_name"
    out="$(clever addon create fs-bucket "$fs_name" --plan s --region "$REGION" --format json 2>&1)"
    fs_id="$(addon_id_by_name "$fs_name")"
    if [ -z "$fs_id" ]; then
      printf '%s\n' "$out" | tail -5
      die "could not create FS Bucket add-on $fs_name"
    fi
    ok "FS Bucket add-on created: $fs_id"
  else
    skip "FS Bucket add-on exists: $fs_id"
  fi
  if is_addon_linked "$name" "$fs_id"; then
    skip "FS Bucket linked"
  else
    clever service link-addon "$fs_id" --alias "$name" >/dev/null 2>&1
    is_addon_linked "$name" "$fs_id" && ok "FS Bucket linked" || die "could not link FS Bucket"
  fi
  bucket_host="$(clever addon env "$fs_id" --format json 2>/dev/null | jq -r '.BUCKET_HOST // ""')"
  [ -n "$bucket_host" ] || die "could not read BUCKET_HOST for $fs_name"

  # --- shared Configuration provider ------------------------------------
  local config_addon_id
  config_addon_id="$(addon_id_by_name "$CONFIG_ADDON")"
  if is_addon_linked "$name" "$config_addon_id"; then
    skip "shared config linked"
  else
    clever service link-addon "$config_addon_id" --alias "$name" >/dev/null 2>&1
    is_addon_linked "$name" "$config_addon_id" && ok "shared config linked" \
      || die "could not link $CONFIG_ADDON"
  fi

  # --- per-VM environment -----------------------------------------------
  # Only what genuinely differs per box lives here; everything shared comes
  # from the Configuration provider. CC_FS_BUCKET paths are resolved
  # relative to APP_HOME, hence the leading "/persistent".
  ensure_env "$name" CC_FS_BUCKET  "/persistent:$bucket_host"
  ensure_env "$name" CELLAR_BUCKET "$name-files"
  ensure_env "$name" VM_AGENT_NAME "$name"

  if $PER_VM_KEY; then
    local key_path="$SECRETS_DIR/$name/id_ed25519"
    ensure_key "$key_path"
    ensure_env "$name" VM_AGENT_SSH_KEY_B64 "$(base64 -w0 < "$key_path")"
  fi

  prune_shadowing_env "$name"

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
  printf '  %-18s %-9s %-3s %-40s %s\n' NAME STATE SIZE APP_ID STATUS_URL
  local name status state flavor id
  while read -r name; do
    [ -n "$name" ] || continue
    status="$(clever status --alias "$name" --format json 2>/dev/null)"
    if [ -z "$status" ]; then
      printf '  %-18s %-9s\n' "$name" "MISSING"
      continue
    fi
    id="$(printf '%s' "$status"     | jq -r '.id')"
    state="$(printf '%s' "$status"  | jq -r '.status')"
    flavor="$(printf '%s' "$status" | jq -r '.instances[0].flavor // "?"')"
    printf '  %-18s %-9s %-3s %-40s %s\n' "$name" "$state" "$flavor" "$id" \
      "https://app-${id#app_}.cleverapps.io/status"
  done < "$FLEET_FILE"
}

do_destroy() {
  local name="$1" confirmed="$2"
  $confirmed || die "refusing to destroy $name without --yes"
  hdr "destroying [$name]"
  # The Configuration provider is fleet-wide and deliberately left alone.
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
  all|provision)
    [ "$ACTION" = all ] && { [ -s "$FLEET_FILE" ] || die "vms.txt is empty - provision a VM first"; }
    [ "$ACTION" = provision ] && [ "${#NAMES[@]}" -eq 0 ] && usage 1

    hdr "shared configuration"
    $PER_VM_KEY || ensure_key "$KEY_PATH"
    CONFIG_ID="$(ensure_config_provider)"
    sync_shared_config "$CONFIG_ID"

    if [ "$ACTION" = all ]; then
      while read -r n; do [ -n "$n" ] && provision_one "$n" "$CONFIG_ID"; done < "$FLEET_FILE"
    else
      for base in "${NAMES[@]}"; do
        if [ "$COUNT" -gt 1 ]; then
          for i in $(seq 1 "$COUNT"); do provision_one "$base-$i" "$CONFIG_ID"; done
        else
          provision_one "$base" "$CONFIG_ID"
        fi
      done
    fi
    ;;
esac

if [ "$ACTION" = "provision" ] || [ "$ACTION" = "all" ]; then
  hdr "commit key to register on your forges"
  cat "${KEY_PATH}.pub"
  printf '\n  GitHub: https://github.com/settings/keys\n'
  printf '  GitLab: glab api --method POST /user/keys -f "title=vm-agent" -f "key=$(cat %s.pub)" -f usage_type=auth_and_signing\n' "$KEY_PATH"
fi
