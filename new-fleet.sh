#!/usr/bin/env bash
# Interactive setup for a brand-new fleet of vm-agent boxes.
#
#     ./new-fleet.sh
#
# Asks for a fleet name, the commit identity, the agent and forge tokens
# and how many VMs you want; writes fleet.conf and .secrets/tokens.env,
# registers the commit key on your forges, then hands over to
# provision.sh, which does the actual creating.
#
# Nothing is created until the summary near the end is confirmed, and
# every question has a default. Re-running it is safe: your current
# answers come back as the defaults and tokens you already have are kept,
# so it doubles as a way to reconfigure an existing fleet.
#
#   ./new-fleet.sh --no-deploy   set everything up, but skip the deploy
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$ROOT/.secrets"
TOKENS="$SECRETS_DIR/tokens.env"
CONF="$ROOT/fleet.conf"
FLEET_FILE="$ROOT/vms.txt"
TMPDIR_W="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_W"' EXIT

DEPLOY_ARGS=()
case "${1:-}" in
  --no-deploy) DEPLOY_ARGS=(--no-deploy) ;;
  -h|--help)   awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"; exit 0 ;;
  "")          ;;
  *)           printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- output
c_ok=$'\033[32m'; c_dim=$'\033[2m'; c_do=$'\033[36m'; c_err=$'\033[31m'
c_warn=$'\033[33m'; c_b=$'\033[1m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_do"   "  → $*" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok"   "  ✓ $*" "$c_off"; }
skip() { printf '%s%s%s\n' "$c_dim"  "  · $*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_warn" "  ! $*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_err"  "  ✗ $*" "$c_off" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$c_b" "$*" "$c_off"; }
note() { printf '%s%s%s\n' "$c_dim" "    $*" "$c_off"; }

# --------------------------------------------------------------- prompts
# A wizard that cannot ask anything is just a confusing way to fail, so
# refuse up front rather than silently accepting every default.
[ -t 0 ] || die "no terminal on stdin - this wizard is interactive; use ./provision.sh directly"

ask() {  # $1 varname, $2 question, $3 default
  local __var="$1" question="$2" def="${3:-}" reply
  if [ -n "$def" ]; then printf '  %s %s[%s]%s: ' "$question" "$c_dim" "$def" "$c_off"
  else                   printf '  %s: ' "$question"; fi
  IFS= read -r reply || die "input closed"
  [ -z "$reply" ] && reply="$def"
  printf -v "$__var" '%s' "$reply"
}

ask_yn() {  # $1 question, $2 default (y|n) -> exit status
  local question="$1" def="${2:-y}" reply hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  while :; do
    printf '  %s %s ' "$question" "$hint"
    IFS= read -r reply || die "input closed"
    [ -z "$reply" ] && reply="$def"
    case "$reply" in [yY]*) return 0 ;; [nN]*) return 1 ;; esac
    warn "please answer y or n"
  done
}

ask_secret() {  # $1 varname, $2 question, $3 current value ("" if none)
  local __var="$1" question="$2" cur="${3:-}" reply
  if [ -n "$cur" ]; then
    printf '  %s %s[keep %s]%s: ' "$question" "$c_dim" "$(mask "$cur")" "$c_off"
  else
    printf '  %s %s[skip]%s: ' "$question" "$c_dim" "$c_off"
  fi
  IFS= read -rs reply || die "input closed"
  printf '\n'
  # Pasting a token often drags in a stray space or newline.
  reply="$(printf '%s' "$reply" | tr -d '[:space:]')"
  [ -z "$reply" ] && reply="$cur"
  printf -v "$__var" '%s' "$reply"
}

mask() { local v="$1"; [ ${#v} -gt 12 ] && printf '%s…%s' "${v:0:6}" "${v: -4}" || printf '%s' "set"; }

# ------------------------------------------------------------- preflight
hdr "checking prerequisites"
for c in clever jq ssh-keygen base64 curl git awk; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required but not installed"
done
ok "clever, jq, ssh-keygen, base64, curl, git"
clever profile >/dev/null 2>&1 || die "not logged in to Clever Cloud - run 'clever login' first"
ok "logged in as $(clever profile 2>/dev/null | awk '/^Email/ {print $2; exit}')"

# Load whatever is already configured, so every default is your own answer.
# shellcheck disable=SC1090
[ -f "$CONF" ]   && . "$CONF"
[ -f "$TOKENS" ] && . "$TOKENS"

# ------------------------------------------------------- existing fleet?
# grep -c already prints 0 when it matches nothing, and exits 1 while
# doing it - so a `|| echo 0` fallback would append a second zero.
EXISTING=0
[ -f "$FLEET_FILE" ] && EXISTING="$(grep -c . "$FLEET_FILE" 2>/dev/null)"
[ -n "$EXISTING" ] || EXISTING=0
if [ "$EXISTING" -gt 0 ]; then
  hdr "a fleet already exists here"
  while read -r n; do [ -n "$n" ] && note "$n"; done < "$FLEET_FILE"
  printf '\n'
  note "vms.txt tracks one fleet per checkout, so these VMs and the new"
  note "ones share it. Tear them down first to start clean."
  printf '\n'
  if ask_yn "destroy the existing fleet before building the new one?" n; then
    printf '  %stype the word %sdestroy%s to confirm:%s ' "$c_warn" "$c_b" "$c_warn" "$c_off"
    IFS= read -r confirm || die "input closed"
    [ "$confirm" = destroy ] || die "not confirmed - nothing was destroyed"
    # Deleting the applications leaves the Cellar bucket, the FS Bucket and
    # the config provider behind - they are fleet-wide, so no single VM
    # teardown may take them. They also keep billing, so ask outright.
    PURGE_ARGS=()
    printf '\n'
    note "the Cellar bucket, the FS Bucket and the config provider are"
    note "fleet-wide: deleting the VMs leaves them behind, still billing."
    note "Deleting them also destroys what the agents stored - workspaces,"
    note "snapshots, uploaded files - and the fleet's shared secrets."
    printf '\n'
    if ask_yn "also delete the shared storage and secrets?" n; then
      PURGE_ARGS=(--purge)
      warn "the agents' stored data goes with them"
    else
      skip "keeping them - a new fleet of the same name reuses them"
    fi
    "$ROOT/provision.sh" --destroy --all ${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"} --yes \
      || die "teardown failed - stopping here"
    EXISTING=0
  else
    skip "keeping them - the new VMs will join this fleet"
  fi
fi

# ---------------------------------------------------------- organisation
# clever targets your personal space when no --org is passed, so choosing
# it means storing nothing rather than storing the user id.
CLEVER_ORG="${CLEVER_ORG:-}"
ORG_LABEL=""
if [ "$EXISTING" -eq 0 ]; then
  hdr "organisation"
  orgs="$(clever curl -s https://api.clever-cloud.com/v2/organisations 2>/dev/null)"
  self_id="$(clever curl -s https://api.clever-cloud.com/v2/self 2>/dev/null | jq -r '.id // empty')"
  if [ -z "$orgs" ] || ! printf '%s' "$orgs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    warn "could not list your organisations - using your personal space"
    CLEVER_ORG=""
  elif [ "$(printf '%s' "$orgs" | jq 'length')" -le 1 ]; then
    skip "personal space (the only one you belong to)"
    CLEVER_ORG=""
  else
    note "the applications and the three shared add-ons are all created here."
    # Personal space first, so the default is the safe one.
    mapfile -t org_ids   < <(printf '%s' "$orgs" | jq -r --arg s "$self_id" 'sort_by(.id != $s) | .[].id')
    mapfile -t org_names < <(printf '%s' "$orgs" | jq -r --arg s "$self_id" 'sort_by(.id != $s) | .[].name')
    printf '\n'
    for i in "${!org_ids[@]}"; do
      printf '  %s%d)%s %-30s %s%s%s\n' \
        "$c_b" "$((i + 1))" "$c_off" "${org_names[$i]}" "$c_dim" "${org_ids[$i]}" "$c_off"
    done
    printf '\n'
    while :; do
      ask pick "organisation" 1
      case "$pick" in ''|*[!0-9]*) warn "enter one of the numbers above"; continue ;; esac
      if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#org_ids[@]}" ]; then
        warn "there is no option $pick"; continue
      fi
      break
    done
    ORG_LABEL="${org_names[$((pick - 1))]}"
    if [ "${org_ids[$((pick - 1))]}" = "$self_id" ]; then CLEVER_ORG=""
    else CLEVER_ORG="${org_ids[$((pick - 1))]}"; fi
    ok "$ORG_LABEL"
  fi
fi

# ------------------------------------------------------------ fleet name
# The three shared add-ons are found by name, so two fleets in the same
# Clever organisation only stay separate if their names differ.
if [ "$EXISTING" -eq 0 ]; then
  hdr "fleet name"
  note "names the shared add-ons: <name>-config, <name>-cellar, <name>-fs."
  note "Reusing a name means reusing that fleet's storage and secrets."
  ask FLEET_NAME "fleet name" "${FLEET_NAME:-vm-agent}"
  case "$FLEET_NAME" in
    *[!a-z0-9-]*|"") die "fleet name must be lowercase letters, digits and dashes" ;;
  esac
else
  FLEET_NAME="${FLEET_NAME:-vm-agent}"
fi
CONFIG_ADDON="$FLEET_NAME-config"
CELLAR_ADDON="$FLEET_NAME-cellar"
FS_ADDON="$FLEET_NAME-fs"

# -------------------------------------------------------------- identity
hdr "commit identity"
note "used for every commit the agents make. The email must be verified on"
note "your forge, or signatures show up as unverified."
ask GIT_USER_NAME  "git user.name"  "${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null)}"
ask GIT_USER_EMAIL "git user.email" "${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null)}"
[ -n "$GIT_USER_NAME" ]  || die "a commit identity is required"
[ -n "$GIT_USER_EMAIL" ] || die "a commit identity is required"
if ask_yn "sign commits with the fleet's SSH key?" "$([ "${GIT_SIGN_COMMITS:-true}" = true ] && echo y || echo n)"; then
  GIT_SIGN_COMMITS=true
else
  GIT_SIGN_COMMITS=false
fi

# ------------------------------------------------------------ agent size
hdr "how many agents"
note "each agent is its own Clever application. Storage and secrets are"
note "shared, so more agents cost VM time only."
while :; do
  ask AGENT_COUNT "number of agents" "${AGENT_COUNT:-2}"
  case "$AGENT_COUNT" in
    ''|*[!0-9]*) warn "that is not a number" ;;
    0)           warn "a fleet needs at least one agent" ;;
    *)           [ "$AGENT_COUNT" -gt 20 ] && { warn "$AGENT_COUNT agents is a lot - $AGENT_COUNT applications billed by the hour"
                   ask_yn "really?" n || continue; }
                 break ;;
  esac
done
if [ "$AGENT_COUNT" -eq 1 ]; then
  ask AGENT_BASE "VM name" "${AGENT_BASE:-agent}"
  VM_LIST="$AGENT_BASE"
else
  ask AGENT_BASE "name prefix" "${AGENT_BASE:-agent}"
  VM_LIST="$(seq -f "$AGENT_BASE-%g" 1 "$AGENT_COUNT" | paste -sd' ')"
fi
case "$AGENT_BASE" in *[!a-z0-9-]*|"") die "VM names must be lowercase letters, digits and dashes" ;; esac

hdr "machine size"
note "S is enough to drive an agent; M gives builds and tests room."
ask FLAVOR "flavor (S, M, L, XL)" "${FLAVOR:-M}"
ask REGION "region (par, grahq, mtl, sgp, syd, wsw)" "${REGION:-par}"

hdr "agent autonomy"
note "default       every command waits for a human"
note "acceptEdits   file edits are automatic, commands still ask"
note "bypassPermissions   no gate at all"
note ""
note "Agents you launch with 'fleet start' have nobody at the keyboard, so"
note "anything stricter than acceptEdits wedges them on the first command."
ask CLAUDE_PERMISSION_MODE "permission mode" "${CLAUDE_PERMISSION_MODE:-acceptEdits}"
case "$CLAUDE_PERMISSION_MODE" in
  default|acceptEdits|bypassPermissions) ;;
  *) die "permission mode must be default, acceptEdits or bypassPermissions" ;;
esac
[ "$CLAUDE_PERMISSION_MODE" = bypassPermissions ] \
  && warn "the VMs hold your forge tokens and a push-capable commit key"

# ---------------------------------------------------------------- tokens
get_tok() { sed -n "s/^export $1=\"\(.*\)\"$/\1/p" "$TOKENS" 2>/dev/null | tail -1; }

hdr "Claude"
note "one long-lived subscription token serves the whole fleet."
CLAUDE_TOK="$(get_tok CLAUDE_CODE_OAUTH_TOKEN)"
if [ -z "$CLAUDE_TOK" ] && command -v claude >/dev/null 2>&1; then
  if ask_yn "run 'claude setup-token' now to mint one?" y; then
    claude setup-token || warn "setup-token exited non-zero - you can still paste a token below"
  fi
fi
ask_secret CLAUDE_TOK "CLAUDE_CODE_OAUTH_TOKEN" "$CLAUDE_TOK"
if [ -n "$CLAUDE_TOK" ]; then
  case "$CLAUDE_TOK" in
    sk-ant-*) ok "Claude token stored" ;;
    *) warn "that does not look like a Claude token - storing it anyway" ;;
  esac
else
  warn "no Claude token - agents will have no model access unless you set an API key"
fi

hdr "extra model keys (optional)"
note "only needed for opencode and codex. Enter to skip."
ANTHROPIC_KEY="$(get_tok ANTHROPIC_API_KEY)"
OPENAI_KEY="$(get_tok OPENAI_API_KEY)"
OPENROUTER_KEY="$(get_tok OPENROUTER_API_KEY)"
ask_secret ANTHROPIC_KEY  "ANTHROPIC_API_KEY"  "$ANTHROPIC_KEY"
ask_secret OPENAI_KEY     "OPENAI_API_KEY"     "$OPENAI_KEY"
ask_secret OPENROUTER_KEY "OPENROUTER_API_KEY" "$OPENROUTER_KEY"

# ---- GitHub -----------------------------------------------------------
hdr "GitHub"
note "needs scopes: repo, workflow, admin:public_key, admin:ssh_signing_key"
note "create one at https://github.com/settings/tokens"
GH_TOK="$(get_tok GH_TOKEN)"
ask_secret GH_TOK "GH_TOKEN" "$GH_TOK"
GH_LOGIN=""
if [ -n "$GH_TOK" ]; then
  code="$(curl -sS -D "$TMPDIR_W/gh.h" -o "$TMPDIR_W/gh.b" -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $GH_TOK" -H "Accept: application/vnd.github+json" \
    https://api.github.com/user 2>/dev/null)"
  if [ "$code" = 200 ]; then
    GH_LOGIN="$(jq -r '.login // empty' "$TMPDIR_W/gh.b" 2>/dev/null)"
    scopes="$(tr -d '\r' < "$TMPDIR_W/gh.h" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | tail -1)"
    ok "GitHub token valid - $GH_LOGIN"
    # A fine-grained token reports no scopes at all; only nag about a
    # classic one that is genuinely missing them.
    if [ -n "$scopes" ]; then
      for s in repo workflow admin:public_key admin:ssh_signing_key; do
        printf '%s' "$scopes" | tr ',' '\n' | tr -d ' ' | grep -qxF "$s" \
          || warn "token is missing the '$s' scope"
      done
    else
      note "fine-grained token - make sure it grants Contents, Workflows and SSH keys"
    fi
  else
    warn "GitHub rejected that token (HTTP $code) - storing it anyway"
  fi
else
  skip "no GitHub token - agents cannot push to GitHub"
fi

# ---- GitLab -----------------------------------------------------------
hdr "GitLab"
ask GITLAB_HOST "GitLab host" "${GITLAB_HOST:-gitlab.com}"
note "needs scopes: api, write_repository"
note "create one at https://$GITLAB_HOST/-/user_settings/personal_access_tokens"
GL_TOK="$(get_tok GITLAB_TOKEN)"
ask_secret GL_TOK "GITLAB_TOKEN" "$GL_TOK"
GL_LOGIN=""
if [ -n "$GL_TOK" ]; then
  code="$(curl -sS -o "$TMPDIR_W/gl.b" -w '%{http_code}' --max-time 20 \
    -H "PRIVATE-TOKEN: $GL_TOK" "https://$GITLAB_HOST/api/v4/user" 2>/dev/null)"
  if [ "$code" = 200 ]; then
    GL_LOGIN="$(jq -r '.username // empty' "$TMPDIR_W/gl.b" 2>/dev/null)"
    ok "GitLab token valid - $GL_LOGIN"
  else
    warn "GitLab rejected that token (HTTP $code) - storing it anyway"
  fi
else
  skip "no GitLab token - agents cannot push to GitLab"
fi

# ---------------------------------------------------------------- review
hdr "review"
printf '  %-22s %s\n' "organisation"     "${ORG_LABEL:-${CLEVER_ORG:-Personal space}}"
printf '  %-22s %s\n' "fleet"            "$FLEET_NAME"
printf '  %-22s %s\n' "VMs"             "$VM_LIST"
printf '  %-22s %s\n' "size / region"   "$FLAVOR / $REGION"
printf '  %-22s %s\n' "commit identity" "$GIT_USER_NAME <$GIT_USER_EMAIL>"
printf '  %-22s %s\n' "sign commits"    "$GIT_SIGN_COMMITS"
printf '  %-22s %s\n' "permission mode" "$CLAUDE_PERMISSION_MODE"
printf '  %-22s %s\n' "Claude"          "$([ -n "$CLAUDE_TOK" ] && mask "$CLAUDE_TOK" || echo '— none')"
printf '  %-22s %s\n' "GitHub"          "$([ -n "$GH_TOK" ] && echo "${GH_LOGIN:-token stored}" || echo '— none')"
printf '  %-22s %s\n' "GitLab"          "$([ -n "$GL_TOK" ] && echo "${GL_LOGIN:-token stored} on $GITLAB_HOST" || echo '— none')"
printf '  %-22s %s\n' "shared add-ons"  "$CONFIG_ADDON, $CELLAR_ADDON, $FS_ADDON"
printf '\n'
note "$AGENT_COUNT application(s) billed by the hour, plus one Cellar and one"
note "FS Bucket add-on. Nothing has been created yet."
printf '\n'
ask_yn "write this configuration and build the fleet?" y || die "nothing was written"

# ----------------------------------------------------------------- write
hdr "writing configuration"
mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"

[ -f "$CONF" ] && { cp "$CONF" "$CONF.bak"; skip "kept your previous fleet.conf as fleet.conf.bak"; }
{
  echo "# Fleet-wide settings for provision.sh - written by ./new-fleet.sh."
  echo "# Gitignored: it carries your name and email. Secrets live in"
  echo "# .secrets/tokens.env (see ./agent-tokens.sh)."
  echo "#"
  echo "# Every value is a default - an environment variable of the same name"
  echo "# wins, so 'FLAVOR=L ./provision.sh big-agent' still works."
  echo
  printf ': "${GIT_USER_NAME:=%s}"\n'   "$GIT_USER_NAME"
  printf ': "${GIT_USER_EMAIL:=%s}"\n'  "$GIT_USER_EMAIL"
  printf ': "${GIT_SIGN_COMMITS:=%s}"\n' "$GIT_SIGN_COMMITS"
  echo
  printf ': "${CLAUDE_PERMISSION_MODE:=%s}"\n' "$CLAUDE_PERMISSION_MODE"
  printf ': "${GITLAB_HOST:=%s}"\n' "$GITLAB_HOST"
  echo
  printf ': "${FLAVOR:=%s}"\n' "$FLAVOR"
  printf ': "${REGION:=%s}"\n' "$REGION"
  echo
  # Empty means the personal space, so write nothing rather than pinning
  # the fleet to a user id that reads like an organisation.
  [ -n "$CLEVER_ORG" ] && {
    echo "# Organisation owning the applications and add-ons."
    printf ': "${CLEVER_ORG:=%s}"\n' "$CLEVER_ORG"
    echo
  }
  echo "# The shared add-ons are looked up by name; these keep this fleet"
  echo "# separate from any other one in the same organisation."
  printf ': "${FLEET_NAME:=%s}"\n'    "$FLEET_NAME"
  printf ': "${CONFIG_ADDON:=%s}"\n'  "$CONFIG_ADDON"
  printf ': "${CELLAR_ADDON:=%s}"\n'  "$CELLAR_ADDON"
  printf ': "${FS_ADDON:=%s}"\n'      "$FS_ADDON"
  # Settings the wizard never asks about, but which a hand-edited
  # fleet.conf may carry. Dropping CELLAR_BUCKET_NAME would silently move
  # the fleet to a different bucket, so anything set is written back.
  [ -n "${CELLAR_BUCKET_NAME:-}" ] && printf ': "${CELLAR_BUCKET_NAME:=%s}"\n' "$CELLAR_BUCKET_NAME"
  [ -n "${KEY_PATH:-}" ]           && printf ': "${KEY_PATH:=%s}"\n'           "$KEY_PATH"
  echo
  echo "# Remembered so ./new-fleet.sh can offer them back as defaults."
  printf ': "${AGENT_BASE:=%s}"\n'  "$AGENT_BASE"
  printf ': "${AGENT_COUNT:=%s}"\n' "$AGENT_COUNT"
} > "$CONF"
ok "fleet.conf"

put_tok() {  # $1 var, $2 value - rewritten in place, never appended twice
  local tmp; tmp="$(mktemp)"
  grep -v "^export $1=" "$TOKENS" > "$tmp" 2>/dev/null || true
  [ -n "$2" ] && printf 'export %s="%s"\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$TOKENS"; chmod 600 "$TOKENS"
}
if [ ! -f "$TOKENS" ]; then
  {
    echo '# Sourced by provision.sh. Gitignored - never commit this file.'
    echo '# An empty value keeps whatever is already in the config provider.'
  } > "$TOKENS"
  chmod 600 "$TOKENS"
fi
put_tok CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_TOK"
put_tok ANTHROPIC_API_KEY       "$ANTHROPIC_KEY"
put_tok OPENAI_API_KEY          "$OPENAI_KEY"
put_tok OPENROUTER_API_KEY      "$OPENROUTER_KEY"
put_tok GH_TOKEN                "$GH_TOK"
put_tok GITLAB_TOKEN            "$GL_TOK"
ok ".secrets/tokens.env"

# ------------------------------------------------------------ commit key
hdr "commit key"
KEY="${KEY_PATH:-$SECRETS_DIR/id_ed25519}"
if [ -f "$KEY" ]; then
  skip "reusing $(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"
else
  ssh-keygen -t ed25519 -C "$FLEET_NAME@clever-cloud" -f "$KEY" -N "" -q \
    || die "could not generate the commit key"
  ok "generated $(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"
fi
PUBKEY="$(cat "$KEY.pub")"
# The forges store the key with their own comment, so compare on the
# algorithm and the key body only.
PUBBODY="$(printf '%s' "$PUBKEY" | awk '{print $1" "$2}')"

gh_has_key() {  # $1 endpoint
  curl -sS --max-time 20 -H "Authorization: Bearer $GH_TOK" \
    -H "Accept: application/vnd.github+json" "https://api.github.com/$1" 2>/dev/null \
    | jq -r '.[]?.key // empty' 2>/dev/null \
    | awk '{print $1" "$2}' | grep -qxF "$PUBBODY"
}
gh_add_key() {  # $1 endpoint, $2 label
  local code
  code="$(curl -sS -o "$TMPDIR_W/o" -w '%{http_code}' --max-time 20 -X POST \
    -H "Authorization: Bearer $GH_TOK" -H "Accept: application/vnd.github+json" \
    -d "$(jq -n --arg t "$FLEET_NAME" --arg k "$PUBKEY" '{title:$t, key:$k}')" \
    "https://api.github.com/$1" 2>/dev/null)"
  case "$code" in
    201) ok "GitHub $2 key registered" ;;
    422) skip "GitHub $2 key already registered" ;;
    *)   warn "could not register the GitHub $2 key (HTTP $code): $(jq -r '.message // empty' "$TMPDIR_W/o" 2>/dev/null)" ;;
  esac
}

REGISTERED_GH=false
if [ -n "$GH_TOK" ] && ask_yn "register this key on GitHub${GH_LOGIN:+ ($GH_LOGIN)}?" y; then
  gh_has_key user/keys              && skip "GitHub auth key already registered"    || gh_add_key user/keys "auth"
  gh_has_key user/ssh_signing_keys  && skip "GitHub signing key already registered" || gh_add_key user/ssh_signing_keys "signing"
  REGISTERED_GH=true
fi

REGISTERED_GL=false
if [ -n "$GL_TOK" ] && ask_yn "register this key on $GITLAB_HOST${GL_LOGIN:+ ($GL_LOGIN)}?" y; then
  if curl -sS --max-time 20 -H "PRIVATE-TOKEN: $GL_TOK" \
       "https://$GITLAB_HOST/api/v4/user/keys" 2>/dev/null \
       | jq -r '.[]?.key // empty' 2>/dev/null | awk '{print $1" "$2}' | grep -qxF "$PUBBODY"; then
    skip "GitLab key already registered"
  else
    code="$(curl -sS -o "$TMPDIR_W/o" -w '%{http_code}' --max-time 20 -X POST \
      -H "PRIVATE-TOKEN: $GL_TOK" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$FLEET_NAME" --arg k "$PUBKEY" \
            '{title:$t, key:$k, usage_type:"auth_and_signing"}')" \
      "https://$GITLAB_HOST/api/v4/user/keys" 2>/dev/null)"
    case "$code" in
      200|201) ok "GitLab key registered for auth and signing" ;;
      400)     skip "GitLab key already registered" ;;
      *)       warn "could not register the GitLab key (HTTP $code): $(jq -r '.message // .error // empty' "$TMPDIR_W/o" 2>/dev/null)" ;;
    esac
  fi
  REGISTERED_GL=true
fi

if ! $REGISTERED_GH || ! $REGISTERED_GL; then
  printf '\n'
  note "register it by hand wherever you skipped:"
  printf '\n%s\n\n' "$PUBKEY"
  $REGISTERED_GH || note "GitHub: https://github.com/settings/keys (and .../ssh/signing)"
  $REGISTERED_GL || note "GitLab: https://$GITLAB_HOST/-/user_settings/ssh_keys"
fi

# --------------------------------------------------------------- build
hdr "building the fleet"
note "handing over to provision.sh - this takes about a minute per VM."
printf '\n'
if [ "$AGENT_COUNT" -eq 1 ]; then
  "$ROOT/provision.sh" "$AGENT_BASE" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"} || die "provisioning failed - fix the error above and re-run ./provision.sh --all"
else
  "$ROOT/provision.sh" "$AGENT_BASE" --count "$AGENT_COUNT" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"} || die "provisioning failed - fix the error above and re-run ./provision.sh --all"
fi

hdr "fleet ready"
note "./tools/fleet status                 who is up"
note "./tools/fleet start <vm> <name>      launch an agent"
note "./tools/fleet attach <vm>/<name>     drive it in herdr"
note "./provision.sh --destroy --all --yes stop billing"
printf '\n'
