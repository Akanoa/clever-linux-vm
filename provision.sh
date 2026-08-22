#!/usr/bin/env bash
# Idempotent provisioner for a fleet of vm-agent boxes on Clever Cloud.
#
# Every step checks the desired state before touching anything, so running
# this twice is a no-op and running it after a partial failure resumes
# where it stopped. Each VM gets its own application; storage is shared -
# one Cellar add-on and one FS Bucket for the fleet, with each VM confined
# to its own subtree of the bucket. Everything the whole fleet shares -
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
#   ./provision.sh --all --forget OPENAI_API_KEY   drop a shared secret
#
#   --force   deploy even while agents are working (kills their panes)
set -uo pipefail

# ---------------------------------------------------------------- config
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$ROOT/.secrets"
FLEET_FILE="$ROOT/vms.txt"
# fleet.conf holds the non-secret fleet settings (identity, size, region)
# and is committed. Anything already in the environment wins over it, so a
# one-off `FLAVOR=L ./provision.sh ...` still works.
[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf"

# .secrets/tokens.env is gitignored and holds the agent and forge tokens;
# ./agent-tokens.sh fills it.
[ -f "$SECRETS_DIR/tokens.env" ] && . "$SECRETS_DIR/tokens.env"

FLAVOR="${FLAVOR:-M}"
REGION="${REGION:-par}"
KEY_PATH="${KEY_PATH:-$SECRETS_DIR/id_ed25519}"
PER_VM_KEY=false
DEPLOY=true
COUNT=1
CONFIG_ADDON="${CONFIG_ADDON:-vm-agent-config}"
CELLAR_ADDON="${CELLAR_ADDON:-vm-agent-cellar}"
# Empty means "derive from the add-on id" - see below.
CELLAR_BUCKET_NAME="${CELLAR_BUCKET_NAME:-}"
FS_ADDON="${FS_ADDON:-vm-agent-fs}"
FORGET=()
FORCE=false
GIT_NAME="${GIT_USER_NAME:-vm-agent}"
GIT_EMAIL="${GIT_USER_EMAIL:-vm-agent@clever-cloud.local}"
SIGN_COMMITS="${GIT_SIGN_COMMITS:-false}"
GITLAB_HOST_VALUE="${GITLAB_HOST:-gitlab.com}"
CLAUDE_PERMISSION_MODE_VALUE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"

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

# --------------------------------------------------- shared storage
# One Cellar add-on and one FS Bucket for the whole fleet. Both are linked
# to every application: object storage is concurrent-safe, and the FS
# Bucket is kept safe by giving each VM its own subtree under vms/<name>
# (see scripts/00-persist.sh) so no box can rsync over another's state.
ensure_shared_addon() {
  local provider="$1" name="$2" plan="$3" id out
  id="$(addon_id_by_name "$name")"
  if [ -z "$id" ]; then
    say "creating $provider add-on $name" >&2
    out="$(clever addon create "$provider" "$name" --plan "$plan" --region "$REGION" --format json 2>&1)"
    id="$(addon_id_by_name "$name")"
    if [ -z "$id" ]; then
      printf '%s\n' "$out" | tail -5 >&2
      die "could not create $provider add-on $name"
    fi
    ok "$provider add-on created: $id" >&2
  else
    skip "$provider add-on exists: $id" >&2
  fi
  printf '%s' "$id"
}

link_addon() {
  local alias="$1" id="$2" label="$3"
  if is_addon_linked "$alias" "$id"; then
    skip "$label linked"
  else
    clever service link-addon "$id" --alias "$alias" >/dev/null 2>&1
    is_addon_linked "$alias" "$id" && ok "$label linked" || die "could not link $label"
  fi
}

# Flags any fs-bucket or Cellar add-on linked to the app that is not the
# fleet's shared one.
warn_stray_storage() {
  local alias="$1" linked catalogue stray
  linked="$(clever service --only-addons --format json --alias "$alias" 2>/dev/null)"
  catalogue="$(clever addon list --format json 2>/dev/null)"
  [ -n "$linked" ] && [ -n "$catalogue" ] || return 0

  stray="$(jq -rn \
    --argjson linked "$linked" --argjson cat "$catalogue" \
    --arg cellar "$CELLAR_ADDON" --arg fs "$FS_ADDON" '
      [ $linked.addons[]?
        | select(.isLinked == true)
        | .name as $n
        | ($cat[] | select(.name == $n) | .providerId) as $p
        | select($p == "fs-bucket" or $p == "cellar-addon")
        | select($n != $cellar and $n != $fs)
        | $n ] | join(" ")')"

  if [ -n "$stray" ]; then
    printf '%s\n' "$c_err  ! $alias also has storage add-ons linked: $stray$c_off" >&2
    printf '%s\n' "$c_err    unlink and delete them, or /persistent may mount the wrong bucket$c_off" >&2
  fi
}

# Every VM's federation endpoint, as name=url pairs. Rebuilt on each run
# so adding a VM re-publishes the roster to the whole fleet.
build_fleet_roster() {
  local name id out=""
  while read -r name; do
    [ -n "$name" ] || continue
    id="$(app_id_by_name "$name")"
    [ -n "$id" ] || continue
    out="${out:+$out,}$name=https://app-${id#app_}.cleverapps.io"
  done < "$FLEET_FILE"
  printf '%s' "$out"
}

# The endpoint is on the public internet, so the token is the only thing
# standing in front of it. Minted once, then carried by the provider.
ensure_fleet_token() {
  local current="$1"
  # Log to stderr: this function's stdout *is* the token. Also validate the
  # shape, so a value corrupted by a stray log line heals itself instead of
  # silently becoming the fleet's shared secret.
  if printf '%s' "$current" | grep -qE '^[0-9a-f]{64}$'; then
    skip "fleet token already minted" >&2
    printf '%s' "$current"
  else
    [ -n "$current" ] && say "stored fleet token is malformed - reminting" >&2
    local minted
    minted="$(mint_token)"
    printf '%s' "$minted" | grep -qE '^[0-9a-f]{64}$' \
      || die "could not generate a fleet token"
    ok "minted a new fleet token" >&2
    printf '%s' "$minted"
  fi
}

# /dev/urandom rather than `openssl rand`: openssl is not guaranteed to be
# present or working (a mismatched libssl exits 0 and prints nothing, which
# would hand the fleet an empty shared secret).
mint_token() {
  if [ -r /dev/urandom ]; then
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  else
    python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null
  fi
}

# Deploying, and any write to the shared config, restarts every linked app
# - which destroys every herdr pane and kills whatever the agents were in
# the middle of. Nothing warned about that, and it has silently thrown away
# work more than once, so check before doing it.
busy_agents() {
  local env_file="$SECRETS_DIR/fleet.env" roster token vm url busy out
  [ -f "$env_file" ] || return 0
  roster="$(sed -n 's/^export VM_AGENT_FLEET="\(.*\)"$/\1/p' "$env_file" | tail -1)"
  token="$(sed -n 's/^export VM_AGENT_FLEET_TOKEN="\(.*\)"$/\1/p' "$env_file" | tail -1)"
  [ -n "$roster" ] && [ -n "$token" ] || return 0

  busy=""
  for entry in $(printf '%s' "$roster" | tr ',' ' '); do
    vm="${entry%%=*}"; url="${entry#*=}"
    out="$(curl -sS --max-time 10 "$url/agents" -H "Authorization: Bearer $token" 2>/dev/null)" || continue
    printf '%s' "$out" | jq -e '.result.agents' >/dev/null 2>&1 || continue
    while read -r a; do
      [ -n "$a" ] && busy="${busy:+$busy }$vm/$a"
    done < <(printf '%s' "$out" | jq -r '.result.agents[]?
             | select(.agent_status=="working" or .agent_status=="blocked")
             | .name // .pane_id')
  done
  [ -z "$busy" ] && return 0
  printf '%s\n' "$c_err  ! agents are mid-task: $busy$c_off" >&2
  printf '%s\n' "$c_err    deploying restarts every VM and destroys their panes.$c_off" >&2
  printf '%s\n' "$c_err    wait, or re-run with --force to kill them anyway.$c_off" >&2
  return 1
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

# Secrets we may not hold locally. An empty local value is read back from
# the provider rather than blanking it, so `--all` without secrets in the
# shell is safe. Anything absent on both sides is simply not written.
SHARED_SECRETS=(
  VM_AGENT_FLEET_TOKEN
  GH_TOKEN GITLAB_TOKEN
  CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
)
# Non-secret settings, always taken from the local configuration.
SHARED_SETTINGS=(GITLAB_HOST GIT_USER_NAME GIT_USER_EMAIL GIT_SIGN_COMMITS CELLAR_BUCKET VM_AGENT_FLEET CLAUDE_PERMISSION_MODE)

# Writes the fleet-wide variables. Changing a value restarts every linked app.
sync_shared_config() {
  local id="$1" current desired var want key
  current="$(cp_read "$id")"
  [ -n "$current" ] || current='[]'

  desired='[]'
  add_var() {
    desired="$(printf '%s' "$desired" \
      | jq --arg n "$1" --arg v "$2" '. + [{name:$n, value:$v}]')"
  }

  $PER_VM_KEY || add_var VM_AGENT_SSH_KEY_B64 "$(base64 -w0 < "$KEY_PATH")"

  add_var GITLAB_HOST      "$GITLAB_HOST_VALUE"
  add_var GIT_USER_NAME    "$GIT_NAME"
  add_var GIT_USER_EMAIL   "$GIT_EMAIL"
  add_var GIT_SIGN_COMMITS "$SIGN_COMMITS"
  add_var CELLAR_BUCKET    "$CELLAR_BUCKET_NAME"
  add_var VM_AGENT_FLEET   "$FLEET_ROSTER"
  add_var CLAUDE_PERMISSION_MODE "$CLAUDE_PERMISSION_MODE_VALUE"

  for var in "${SHARED_SECRETS[@]}"; do
    # --forget is the only way to take a secret back out: an empty local
    # value means "keep what the provider has", not "delete it".
    if [ "${#FORGET[@]}" -gt 0 ] && printf '%s\n' "${FORGET[@]}" | grep -qxF "$var"; then
      printf '%s' "$current" | jq -e --arg n "$var" '.[]? | select(.name==$n)' >/dev/null 2>&1 \
        && ok "$var will be removed from the shared config"
      continue
    fi
    want="${!var:-}"
    [ -z "$want" ] && want="$(printf '%s' "$current" \
      | jq -r --arg n "$var" '.[]? | select(.name==$n) | .value' | head -1)"
    [ -n "$want" ] && add_var "$var" "$want"
  done

  if [ "$(printf '%s' "$current" | jq -S 'sort_by(.name)')" = "$(printf '%s' "$desired" | jq -S 'sort_by(.name)')" ]; then
    skip "shared config already up to date ($(printf '%s' "$desired" | jq 'length') variables)"
  else
    cp_write "$id" "$desired" >/dev/null
    if [ "$(cp_read "$id" | jq -S 'sort_by(.name)')" = "$(printf '%s' "$desired" | jq -S 'sort_by(.name)')" ]; then
      ok "shared config written ($(printf '%s' "$desired" | jq 'length') variables)"
      printf '%s' "$desired" | jq -r '.[] | "      \(.name)"'
    else
      die "could not write the shared configuration"
    fi
  fi
}

# Values set directly on an application shadow the provider, so anything
# the provider now owns must be cleared from the app.
prune_shadowing_env() {
  local alias="$1" key
  for key in VM_AGENT_SSH_KEY_B64 "${SHARED_SETTINGS[@]}" "${SHARED_SECRETS[@]}"; do
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
  # Vertical only. A vm-agent is a pet, not cattle: its herdr server, its
  # workspace and its agent state all live on one box, and a second
  # instance of the *same* app would share VM_AGENT_NAME - so both would
  # rsync --delete into the same subtree of the FS Bucket, and `clever ssh`
  # would drop you on whichever one it felt like. NFS locks here are
  # local_lock=all, so there is no cross-instance lock to save us either.
  # Scale out by adding VMs (`--count`), never by adding instances.
  local status_json current_flavor instance_count h_max
  status_json="$(clever status --alias "$name" --format json 2>/dev/null)"
  current_flavor="$(printf '%s' "$status_json"  | jq -r '.instances[0].flavor // ""')"
  instance_count="$(printf '%s' "$status_json"  | jq -r '.instances[0].count // 1')"
  h_max="$(printf '%s' "$status_json" | jq -r '.scalability.horizontal.max // 1')"

  if [ "$current_flavor" = "$FLAVOR" ]; then
    skip "flavor already $FLAVOR"
  else
    clever scale --flavor "$FLAVOR" --alias "$name" >/dev/null 2>&1 && ok "scaled to $FLAVOR"
  fi

  if [ "$instance_count" = "1" ] && [ "$h_max" = "1" ]; then
    skip "pinned to a single instance"
  else
    clever scale --instances 1 --alias "$name" >/dev/null 2>&1 \
      && ok "pinned to a single instance (was count=$instance_count, max=$h_max)" \
      || die "could not pin $name to one instance"
  fi

  # --- shared storage ---------------------------------------------------
  link_addon "$name" "$CELLAR_ID" "Cellar"
  link_addon "$name" "$FS_ID"     "FS Bucket"

  # A leftover per-VM add-on from the days before storage was shared will
  # silently win the /persistent mount over the one CC_FS_BUCKET names,
  # so the box ends up on the wrong bucket with no error anywhere.
  warn_stray_storage "$name"

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
  ensure_env "$name" CC_FS_BUCKET  "/persistent:$FS_BUCKET_HOST"
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
    local want out got
    want="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    got="$(clever status --alias "$name" --format json 2>/dev/null | jq -r '.commit // ""')"

    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      skip "already running $(printf '%.7s' "$want")"
    else
      say "deploying $(printf '%.7s' "$want")"
      # --force: the Clever remote is a deploy target, not a source of
      # truth, so a rewritten local history must win. --same-commit-policy
      # restart makes a no-op deploy pick up changed environment instead
      # of erroring.
      out="$(clever deploy --alias "$name" --force --same-commit-policy restart 2>&1)"

      # Judge by the commit the platform reports, not by the exit code or
      # by grepping the log: a rejected push once slipped through both.
      got="$(clever status --alias "$name" --format json 2>/dev/null | jq -r '.commit // ""')"
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -15
        die "$name is running ${got:-nothing}, expected $want"
      fi
      ok "deployed $(printf '%.7s' "$want")"
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
  # Storage and configuration are fleet-wide; only the application goes.
  # The VM's subtree on the FS Bucket is left in place - deleting an app
  # should not silently destroy whatever was still in its workspace.
  skip "shared add-ons ($CELLAR_ADDON, $FS_ADDON, $CONFIG_ADDON) left alone"
  say "its data stays at vms/$name on the FS Bucket; remove it by hand if you want it gone"
  if [ -n "$(app_id_by_name "$name")" ]; then
    clever delete --alias "$name" --yes >/dev/null 2>&1 && ok "deleted application $name"
  else
    skip "application $name does not exist"
  fi
  [ -f "$FLEET_FILE" ] && { grep -vxF "$name" "$FLEET_FILE" > "$FLEET_FILE.tmp" || true; mv "$FLEET_FILE.tmp" "$FLEET_FILE"; }
}

# So `tools/fleet` works from the laptop too, not just from a VM where the
# provider supplies these.
write_local_fleet_env() {
  local f="$SECRETS_DIR/fleet.env" tmp
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  tmp="$(mktemp)"
  {
    echo "# Generated by provision.sh - gitignored, do not commit."
    printf 'export VM_AGENT_FLEET=%s\n' "\"$FLEET_ROSTER\""
    printf 'export VM_AGENT_FLEET_TOKEN=%s\n' "\"$VM_AGENT_FLEET_TOKEN\""
  } > "$tmp"
  # Report a change only when there is one, so a no-op run stays silent.
  if [ -f "$f" ] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    skip "${f/#$ROOT\//} already current"
  else
    mv "$tmp" "$f"; chmod 600 "$f"
    ok "wrote ${f/#$ROOT\//} for the local fleet client"
  fi
}

print_header_comment() {
  # The full leading comment block - not a fixed line range, which silently
  # truncates the help as soon as anyone adds a line to it.
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}
usage() { print_header_comment; exit "${1:-0}"; }

# ------------------------------------------------------------------ main
need clever; need jq; need ssh-keygen; need base64

NAMES=(); ACTION="provision"; CONFIRMED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --flavor)   FLAVOR="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    --count)    COUNT="$2"; shift 2 ;;
    --cellar)   CELLAR_ADDON="$2"; shift 2 ;;
    --fs)       FS_ADDON="$2"; shift 2 ;;
    --config)   CONFIG_ADDON="$2"; shift 2 ;;
    --forget)   FORGET+=("$2"); shift 2 ;;
    --key)      KEY_PATH="$2"; shift 2 ;;
    --per-vm-key) PER_VM_KEY=true; shift ;;
    --no-deploy)  DEPLOY=false; shift ;;
    --all)      ACTION="all"; shift ;;
    --list)     ACTION="list"; shift ;;
    --destroy)  ACTION="destroy"; NAMES+=("$2"); shift 2 ;;
    --yes|-y)   CONFIRMED=true; shift ;;
    --force)    FORCE=true; shift ;;
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

    if ! $FORCE; then busy_agents || die "aborted to protect running agents"; fi

    hdr "shared resources"
    $PER_VM_KEY || ensure_key "$KEY_PATH"
    CONFIG_ID="$(ensure_config_provider)"
    CELLAR_ID="$(ensure_shared_addon cellar-addon "$CELLAR_ADDON" S)"
    # Cellar bucket names are globally unique across the whole provider, so
    # a friendly name like "vm-agent-files" collides with other tenants and
    # survives a teardown as an unreachable 409/403. Deriving it from the
    # add-on's own id makes it unique, and makes a recreated add-on get a
    # fresh bucket rather than inherit a name it cannot open.
    if [ -z "$CELLAR_BUCKET_NAME" ]; then
      cellar_real="$(addon_real_id_by_name "$CELLAR_ADDON")"
      CELLAR_BUCKET_NAME="vm-agent-$(printf '%s' "${cellar_real#cellar_}" | tr -d - | cut -c1-12)"
      [ "$CELLAR_BUCKET_NAME" = "vm-agent-" ] && die "could not derive a Cellar bucket name"
    fi
    FS_ID="$(ensure_shared_addon fs-bucket "$FS_ADDON" s)"
    FS_BUCKET_HOST="$(clever addon env "$FS_ID" --format json 2>/dev/null | jq -r '.BUCKET_HOST // ""')"
    [ -n "$FS_BUCKET_HOST" ] || die "could not read BUCKET_HOST for $FS_ADDON"
    touch "$FLEET_FILE"
    FLEET_ROSTER="$(build_fleet_roster)"
    VM_AGENT_FLEET_TOKEN="$(ensure_fleet_token "$(cp_read "$CONFIG_ID" \
      | jq -r '.[]? | select(.name=="VM_AGENT_FLEET_TOKEN") | .value' | head -1)")"
    export VM_AGENT_FLEET_TOKEN
    sync_shared_config "$CONFIG_ID"
    write_local_fleet_env

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

    # A brand-new VM has no app id until it has been created, so the roster
    # built before the loop cannot name it. Republish now that every app
    # exists; sync_shared_config only writes when something actually
    # changed, so a stable fleet costs nothing here.
    hdr "fleet roster"
    FLEET_ROSTER="$(build_fleet_roster)"
    sync_shared_config "$CONFIG_ID"
    write_local_fleet_env
    ;;
esac

if [ "$ACTION" = "provision" ] || [ "$ACTION" = "all" ]; then
  hdr "commit key to register on your forges"
  cat "${KEY_PATH}.pub"
  printf '\n  GitHub: https://github.com/settings/keys\n'
  printf '  GitLab: glab api --method POST /user/keys -f "title=vm-agent" -f "key=$(cat %s.pub)" -f usage_type=auth_and_signing\n' "$KEY_PATH"
fi
