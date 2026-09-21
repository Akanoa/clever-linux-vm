#!/usr/bin/env bash
# Entrypoint for a vm-agent pod.
#
# Two shapes, one image, chosen by VM_AGENT_MODE:
#
#   job  a single headless run. The prompt arrives in the environment, the
#        agent answers on stdout, the answer is kept in ~/out and copied to
#        Cellar, and the container exits with the agent's status. Nothing
#        is attached, nothing is prompted twice - this is the disposable
#        shape, and the one Kubernetes is actually good at.
#   pod  a herdr server and the same :8080 endpoint the VMs serve, so
#        `swarm` can prompt, read and abort exactly the way `fleet` does.
#        The pod outlives the order; it is killed, not finished.
#
# Credentials, git identity, Cellar and the agents' onboarding seeds are
# not reimplemented here: scripts/10-secrets.sh and scripts/15-agent-auth.sh
# are the ones the fleet runs, copied into the image and run verbatim. A
# pod that authenticates differently from a VM is a bug waiting for a bad
# afternoon.
set -uo pipefail

export APP_HOME="${APP_HOME:-/opt/vm-agent}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# lib.sh reads these; health-server.py reads the first two back.
export STATE_FILE="${STATE_FILE:-/tmp/vm-agent-state}"
export BOOT_LOG="${BOOT_LOG:-/tmp/vm-agent-boot.log}"
export PERSIST_ROOT="${PERSIST_ROOT:-$HOME/.vm-agent-ephemeral}"

. "$APP_HOME/scripts/lib.sh"

# The pod's name is the agent's name. Kubernetes already guarantees it is
# unique in the namespace, so there is nothing to invent.
export VM_AGENT_NAME="${VM_AGENT_NAME:-$(hostname)}"
MODE="${VM_AGENT_MODE:-pod}"
KIND="${VM_AGENT_KIND:-claude}"

exec > >(tee -a "$BOOT_LOG") 2>&1

stage "starting"
log "vm-agent pod ${VM_AGENT_NAME} (mode=$MODE kind=$KIND)"

mkdir -p "$HOME/workspace" "$HOME/out"

# ------------------------------------------------------------- workspace
# A pod has no bucket to restore from, so whatever it is meant to work on
# has to be fetched. One repository, because a disposable agent with an
# open-ended checkout list is a VM with extra steps.
AGENT_CWD="$HOME/workspace"
clone_repo() {
  [ -n "${VM_AGENT_REPO:-}" ] || return 0
  local dir; dir="$HOME/workspace/$(basename "${VM_AGENT_REPO%.git}")"
  if [ -d "$dir/.git" ]; then
    log "repository already present at $dir"
  elif git clone --quiet "$VM_AGENT_REPO" "$dir"; then
    log "cloned $VM_AGENT_REPO"
  else
    log "ERROR: could not clone $VM_AGENT_REPO - the agent will start in ~/workspace"
    return 1
  fi
  if [ -n "${VM_AGENT_REF:-}" ]; then
    git -C "$dir" checkout --quiet "$VM_AGENT_REF" \
      && log "checked out $VM_AGENT_REF" \
      || log "ERROR: no such ref: $VM_AGENT_REF"
  fi
  AGENT_CWD="$dir"
}

# --------------------------------------------------------------- results
# ~/out is where an answer goes, on a VM and here alike. On a VM it is a
# symlink onto the FS Bucket and survives the box; a pod has no bucket, so
# the copy that outlives it goes to Cellar under k8s/<name>/. Best effort
# on purpose: no Cellar add-on must not stop an agent from running.
CELLAR_PREFIX="k8s/${VM_AGENT_NAME}"
push_out() {
  [ -n "${CELLAR_BUCKET:-}" ] || return 0
  [ -n "$(ls -A "$HOME/out" 2>/dev/null)" ] || return 0
  have s3cmd || return 0
  s3cmd put --quiet --recursive "$HOME/out/" "s3://$CELLAR_BUCKET/$CELLAR_PREFIX/" \
    >/dev/null 2>&1 \
    && log "results copied to s3://$CELLAR_BUCKET/$CELLAR_PREFIX/" \
    || log "could not copy results to Cellar"
}

# ------------------------------------------------------------- toolbelt
# The VM's toolbelt note (scripts/25-toolbelt.sh) describes a box with a
# bucket, a neighbouring fleet and a borrowed Docker daemon, none of which
# a pod has. Short and true beats long and wrong.
write_toolbelt() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/CLAUDE.md" <<TOOLBELT
You are running in a Kubernetes pod named \`${VM_AGENT_NAME}\`, on a Clever
Cloud cluster, as one agent of a vm-agent fleet. **Nothing on this
filesystem survives the pod.** There is no bucket and no snapshot here -
that is the VM fleet's arrangement, not yours.

Two places your work can leave from, and only two:

- **git**. The commit key and the forge tokens are installed, and
  \`gh\`/\`glab\` are authenticated. Pushing a branch is the durable answer.
- **\`~/out/\`**. Anything written there is served over this pod's endpoint
  and copied to Cellar under \`${CELLAR_PREFIX}/\` when the pod stops. This is
  how a result is collected; the terminal is not read, because agent UIs
  collapse tool output into "Ran 1 shell command".

\`cellar put|get|ls|url <key>\` reaches the fleet's shared S3 bucket for
anything too big for git. \`fleet status|agents|prompt|task\` reaches the
long-lived VMs, if this fleet has any - they have persistent workspaces and
are the right place to park something that must outlive you.

\`ripwire <dir> --for="task"\` is a parsed call graph, not a text scanner:
reach for it over \`rg\` for "who calls X", "what implements Y", "which
tests cover Z".

There is no \`sudo\`, no package manager worth using, and no Docker daemon.
TOOLBELT
  log "toolbelt note written to ~/.claude/CLAUDE.md"
}

# ------------------------------------------------------------ provisioning
stage "secrets"
bash "$APP_HOME/scripts/10-secrets.sh"    || log "secrets step reported errors"

stage "agent-auth"
bash "$APP_HOME/scripts/15-agent-auth.sh" || log "agent auth step reported errors"

stage "workspace"
clone_repo || true
write_toolbelt || true

# --------------------------------------------------------------- job mode
# `claude -p` and its equivalents answer on stdout, which is the one place
# an agent's output is *not* folded away - so unlike the pane agents the
# fleet drives, a job's result needs no round trip through a file. It gets
# one anyway, because stdout lives only as long as the pod's log does.
run_job() {
  local prompt out rc
  if [ -n "${VM_AGENT_PROMPT_B64:-}" ]; then
    prompt="$(printf '%s' "$VM_AGENT_PROMPT_B64" | base64 -d)"
  else
    prompt="${VM_AGENT_PROMPT:-}"
  fi
  if [ -z "$prompt" ]; then
    log "FATAL: job mode needs VM_AGENT_PROMPT_B64 (or VM_AGENT_PROMPT)"
    return 64
  fi

  out="$HOME/out/${VM_AGENT_NAME}.md"
  stage "working"
  log "running $KIND in $AGENT_CWD (timeout ${VM_AGENT_TIMEOUT:-3600}s)"
  cd "$AGENT_CWD" || cd "$HOME"

  # Each agent's own headless verb. The permission seeds written by
  # 15-agent-auth.sh apply here too, so nothing below re-argues them -
  # except claude, whose -p honours the flag over the settings file and
  # gives a clearer failure when the mode is not what was asked for.
  local -a argv
  case "$KIND" in
    claude)
      argv=(claude -p "$prompt")
      [ -n "${CLAUDE_PERMISSION_MODE:-}" ] \
        && argv+=(--permission-mode "$CLAUDE_PERMISSION_MODE") ;;
    codex)    argv=(codex exec "$prompt") ;;
    opencode) argv=(opencode run "$prompt") ;;
    *)        log "FATAL: unsupported VM_AGENT_KIND for job mode: $KIND"; return 64 ;;
  esac

  # tee, not redirect: stdout is what `kubectl logs` shows while the job
  # runs, and the file is what survives it.
  timeout "${VM_AGENT_TIMEOUT:-3600}" "${argv[@]}" 2>&1 | tee "$out"
  rc="${PIPESTATUS[0]}"

  if [ "$rc" = 124 ]; then
    log "TIMED OUT after ${VM_AGENT_TIMEOUT:-3600}s - partial answer kept in ~/out"
    printf '\n\n_(timed out after %ss; this answer is partial)_\n' \
      "${VM_AGENT_TIMEOUT:-3600}" >> "$out"
  fi
  stage "done"
  push_out
  log "job finished (exit $rc), $(wc -c < "$out") bytes in ${out##*/}"
  return "$rc"
}

# --------------------------------------------------------------- pod mode
run_pod() {
  # Where POST /agents puts a new pane when the caller names no directory.
  # Without it every agent would start in ~/workspace and have to be told
  # to cd into the one repository the pod was created for.
  export VM_AGENT_DEFAULT_CWD="$AGENT_CWD"

  stage "herdr"
  bash "$APP_HOME/scripts/40-herdr.sh" || log "herdr step reported errors"

  # The pod is killed, never finished, so the only chance to save results
  # is on the way out. SIGTERM arrives with terminationGracePeriodSeconds
  # to spare, which is what that budget in the manifest is for.
  local health_pid=""
  shutdown() {
    log "SIGTERM - flushing results before the pod goes"
    push_out
    [ -n "$health_pid" ] && kill "$health_pid" 2>/dev/null
    exit 0
  }
  trap shutdown TERM INT

  # A periodic copy as well, because a pod evicted or OOM-killed gets no
  # SIGTERM at all and the trap above never runs.
  (
    while sleep "${VM_AGENT_OUT_SYNC:-120}"; do push_out >/dev/null 2>&1; done
  ) &

  stage "ready"
  log "ready - drive it with: swarm prompt ${VM_AGENT_NAME}/<agent> \"...\""

  # Supervised, for the same reason boot.sh supervises it on a VM: the
  # endpoint is the only way in, and letting the kubelet restart the whole
  # container instead would take herdr and every agent's context with it.
  local backoff=1 started lifetime rc
  while :; do
    python3 "$APP_HOME/scripts/health-server.py" &
    health_pid=$!
    log "status endpoint on 0.0.0.0:8080 (pid $health_pid)"
    started=$SECONDS
    wait "$health_pid"; rc=$?
    lifetime=$(( SECONDS - started ))
    log "status endpoint exited (rc=$rc) - relaunching in ${backoff}s"
    sleep "$backoff"
    if [ "$lifetime" -ge 60 ]; then backoff=1
    elif [ "$backoff" -lt 30 ]; then backoff=$(( backoff * 2 )); fi
  done
}

case "$MODE" in
  job) run_job; exit $? ;;
  pod) run_pod ;;
  *)   log "FATAL: VM_AGENT_MODE must be 'job' or 'pod', got '$MODE'"; exit 64 ;;
esac
