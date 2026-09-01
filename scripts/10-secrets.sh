#!/usr/bin/env bash
# Install the commit SSH key, git identity, forge tokens and Cellar config.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

install_ssh_key() {
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  local key="$HOME/.ssh/id_ed25519"

  if [ -n "${VM_AGENT_SSH_KEY_B64:-}" ]; then
    printf '%s' "$VM_AGENT_SSH_KEY_B64" | base64 -d > "$key"
  elif [ -n "${VM_AGENT_SSH_KEY:-}" ]; then
    printf '%s\n' "$VM_AGENT_SSH_KEY" > "$key"
  else
    log "no VM_AGENT_SSH_KEY_B64 set - skipping commit key install"
    return 0
  fi

  chmod 600 "$key"
  ssh-keygen -y -f "$key" > "$key.pub" 2>/dev/null || {
    log "ERROR: the provided key is not a valid OpenSSH private key"
    return 1
  }
  chmod 644 "$key.pub"

  # Pre-trust the forges so non-interactive git over SSH does not stall on
  # a host key prompt.
  : > "$HOME/.ssh/known_hosts.tmp"
  for host in github.com gitlab.com; do
    ssh-keyscan -t rsa,ecdsa,ed25519 "$host" >> "$HOME/.ssh/known_hosts.tmp" 2>/dev/null
  done
  [ -n "${GITLAB_HOST:-}" ] && [ "${GITLAB_HOST}" != "gitlab.com" ] && \
    ssh-keyscan -t rsa,ecdsa,ed25519 "$GITLAB_HOST" >> "$HOME/.ssh/known_hosts.tmp" 2>/dev/null
  mv "$HOME/.ssh/known_hosts.tmp" "$HOME/.ssh/known_hosts"
  chmod 600 "$HOME/.ssh/known_hosts"

  cat > "$HOME/.ssh/config" <<'SSHCFG'
Host *
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ServerAliveInterval 60
SSHCFG
  chmod 600 "$HOME/.ssh/config"
  log "commit key installed: $(ssh-keygen -lf "$key.pub" | awk '{print $2}')"
}

configure_git() {
  git config --global user.name  "${GIT_USER_NAME:-vm-agent}"
  git config --global user.email "${GIT_USER_EMAIL:-vm-agent@clever-cloud.local}"
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global --add safe.directory '*'

  # Sign commits with the same SSH key. Off by default: flip
  # GIT_SIGN_COMMITS=true once the public key is registered as a *signing*
  # key on the forge, otherwise every commit shows as unverified.
  if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    git config --global gpg.format ssh
    git config --global user.signingkey "$HOME/.ssh/id_ed25519.pub"
    git config --global commit.gpgsign "${GIT_SIGN_COMMITS:-false}"

    # Without an allowed-signers file `git log --show-signature` errors out
    # locally even though the signature itself is valid on the forge.
    printf '%s %s\n' "${GIT_USER_EMAIL:-vm-agent@clever-cloud.local}" \
      "$(cat "$HOME/.ssh/id_ed25519.pub")" > "$HOME/.ssh/allowed_signers"
    git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
  fi
  log "git identity: $(git config --global user.name) <$(git config --global user.email)>"
}

configure_gh() {
  if [ -z "${GH_TOKEN:-}" ]; then
    log "GH_TOKEN empty - GitHub CLI left unauthenticated"
    return 0
  fi
  # gh reads GH_TOKEN from the environment on every call; `auth setup-git`
  # additionally makes git push over HTTPS use it.
  gh auth setup-git 2>/dev/null || true
  gh auth status 2>&1 | sed 's/^/[gh] /' || log "gh auth check failed"
}

configure_glab() {
  if [ -z "${GITLAB_TOKEN:-}" ]; then
    log "GITLAB_TOKEN empty - GitLab CLI left unauthenticated"
    return 0
  fi
  local host="${GITLAB_HOST:-gitlab.com}"
  # `glab config set -h <host> token` stores a token but never registers
  # the host, and `glab auth status` only reports on hosts it knows about -
  # so on a *fresh* VM it announced "gitlab.corp... has not been
  # authenticated" in the boot log while `glab api user` worked perfectly
  # off the environment variable. Existing VMs hid this: their config had
  # picked up a host entry from some earlier interactive login, so the bug
  # only ever showed on the first boot of a new box.
  #
  # `auth login --token` registers the host, which is what status reads. It
  # warns that GITLAB_TOKEN takes precedence over what it just stored -
  # that is fine and is what we want: the env stays the source of truth,
  # this only teaches glab the host exists.
  glab auth login --hostname "$host" --token "$GITLAB_TOKEN" >/dev/null 2>&1 || true
  glab config set -h "$host" git_protocol ssh >/dev/null 2>&1 || true
  glab auth status 2>&1 | sed 's/^/[glab] /' || log "glab auth check failed"
}

# git over HTTPS to the GitLab host, the way `gh auth setup-git` does it for
# GitHub: a helper that reads `$GITLAB_TOKEN` at call time.
#
# Deliberately **not** a credential file. Two things go wrong with one, and both
# have: a copy written by hand is a second place the token has to be rotated, and
# it goes stale silently — a wrong value there fails exactly like a revoked token.
# And `$HOME` is local disk, rebuilt on every boot, so `~/.git-credentials`
# disappears on the next restart while `~/workspace` (the bucket) keeps a copy
# git never looks at. Reading the environment has neither problem: there is one
# value, the current one, and a rotation lands with the restart that publishes it.
#
# Registered per-host so it cannot answer for github.com, which `gh` owns.
configure_git_https() {
  local host="${GITLAB_HOST:-gitlab.com}"
  if [ -z "${GITLAB_TOKEN:-}" ]; then
    log "GITLAB_TOKEN empty - git over HTTPS to $host left unauthenticated"
    return 0
  fi
  git config --global --replace-all "credential.https://$host.helper" \
    '!f() { echo username=oauth2; echo "password=${GITLAB_TOKEN}"; }; f'
  log "git https credential helper installed for $host"
}

configure_cellar() {
  if [ -z "${CELLAR_ADDON_KEY_ID:-}" ]; then
    log "no Cellar credentials in the environment - skipping s3cmd config"
    return 0
  fi
  cat > "$HOME/.s3cfg" <<S3CFG
[default]
access_key = ${CELLAR_ADDON_KEY_ID}
secret_key = ${CELLAR_ADDON_KEY_SECRET}
host_base = ${CELLAR_ADDON_HOST}
host_bucket = %(bucket)s.${CELLAR_ADDON_HOST}
use_https = True
signature_v2 = False
S3CFG
  chmod 600 "$HOME/.s3cfg"

  # Also expose the credentials the AWS-style SDKs expect, so agents can
  # use boto3/aws-sdk against Cellar without extra wiring.
  mkdir -p "$HOME/.aws"
  cat > "$HOME/.aws/credentials" <<AWSCFG
[default]
aws_access_key_id = ${CELLAR_ADDON_KEY_ID}
aws_secret_access_key = ${CELLAR_ADDON_KEY_SECRET}
AWSCFG
  cat > "$HOME/.aws/config" <<AWSCFG
[default]
region = us-east-1
endpoint_url = https://${CELLAR_ADDON_HOST}
AWSCFG
  chmod 600 "$HOME/.aws/credentials"

  local bucket="${CELLAR_BUCKET:-}"
  if [ -n "$bucket" ]; then
    if s3cmd ls "s3://$bucket" >/dev/null 2>&1; then
      log "cellar bucket ready: s3://$bucket"
    else
      s3cmd mb "s3://$bucket" 2>&1 | sed 's/^/[cellar] /'
    fi
  fi
}

install_ssh_key || true
configure_git   || true
configure_gh    || true
configure_glab  || true
configure_git_https || true
configure_cellar || true
