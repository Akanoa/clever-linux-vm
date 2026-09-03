#!/usr/bin/env bash
# Tell agents what this box gives them.
#
# An installed binary an agent never learns about is not a toolbelt, so the
# box documents itself in ~/.claude/CLAUDE.md, which Claude Code loads as
# user-level context. Written between markers: anything you add outside
# them survives a redeploy.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DOC="$HOME/.claude/CLAUDE.md"
BEGIN="<!-- >>> vm-agent toolbelt >>> -->"
END="<!-- <<< vm-agent toolbelt <<< -->"

mkdir -p "$HOME/.claude"

# Only on a VM that has one - documenting a daemon that is not there would
# send agents chasing a socket that will never appear.
docker_section=""
if [ -n "${VM_AGENT_DOCKERD:-}" ]; then
  docker_section="$(cat <<'DOCKER'
## Docker and Testcontainers

This box has a working `DOCKER_HOST`, but **the daemon is not on this box** -
it runs on a companion app and arrives over an ssh tunnel. Every shell gets
the environment already; `docker ps` and Testcontainers just work.

```sh
docker ps                 # the companion's daemon
./tunnel.sh status        # is the tunnel up, what is forwarded
./tunnel.sh doctor        # start a real container and reach it, end to end
./tunnel.sh restart       # if the socket ever goes quiet
```

Published ports are forwarded to **this VM's localhost at the same port
number**, so `getHost()` + `getMappedPort()` resolve to something you can
actually connect to, and no `TESTCONTAINERS_HOST_OVERRIDE` juggling is
needed - it is set for you.

Two things do not work, both because the daemon's filesystem is not this
one:

- **Bind mounts of local paths** (`-v $PWD:/x`, `withFileSystemBind`). The
  path is resolved over there, where it does not exist. Copy instead:
  `withCopyFileToContainer(MountableFile.forHostPath(...), ...)`, which
  ships the bytes over the API.
- **`Testcontainers.exposeHostPorts()`** - the reverse direction, a
  container reaching a server running here. The tunnel is one-way.

If a container starts and the test cannot reach it, check `./tunnel.sh
status` first: the forward is added when the container starts, so a dead
tunnel looks exactly like a broken test.

DOCKER
)"
fi

block="$(cat <<BLOCK
$BEGIN
# This machine

A Clever Cloud VM named \`${VM_AGENT_NAME:-vm-agent}\`, one of a fleet. No root, no
package manager - use \`mise\` for extra runtimes. Only \`~/workspace\` and the
directories below survive a redeploy.

## moerae - memory that outlives context compaction

Long tasks lose their context to compaction. \`moerae\` is a local memory
system (no API key, no service) - store findings as you go and search them
back afterwards.

\`\`\`sh
conv=\$(moerae put -p PROJECT "a finding worth keeping")   # prints a conversation id
moerae put -p PROJECT -c "\$conv" "another finding"        # SAME conversation
moerae search -p PROJECT -c "\$conv" "what did I learn about X"
moerae get -p PROJECT <node_id>                           # full content
moerae stats -p PROJECT
\`\`\`

**The conversation id is everything.** Every \`put\` *without* \`-c\` starts a new
conversation, and a \`search\` without \`-c\` only looks at the newest one.
Measured on this box: for a young conversation, both a bare \`search\` and
\`--project-scope\` return **zero rows and exit 0** - no error, just silence.
So:

- Save the conversation id the moment the first \`put\` returns it. Write it
  into a file under \`~/workspace\`, not just shell history.
- If you lose it, \`moerae convs -p PROJECT\` lists the ids - that is the only
  way back to your own memory.

**\`put\` has a token limit, and failures are currently silent.** Content over
~128 indexable tokens is rejected with exit 1 and - until
[Moerae-AI/Moerae#3](https://github.com/Moerae-AI/Moerae/issues/3) is merged -
*no message at all*, because the CLI redirects stderr to /dev/null and never
restores it. So:

- Keep a \`put\` to roughly a paragraph, or pass \`-m/--metadata\` for large content.
- Always check \`\$?\`. A silent success and a silent failure look identical.
- Chaining puts with \`&&\` is fine. If a chain stops early it is because one of
  them hit the token limit, not because chaining is broken.

Use \`-p\` per project/repo. First use downloads a ~300MB embedding model
(~12s); the model is deliberately not persisted, the memory is.

## Other tools here

- \`cellar put|get|ls|url <key>\` - S3 bucket shared by the fleet, for files
  too big or too transient for git.
- \`fleet status|agents|start|prompt|read\` - the other VMs. You can launch and
  drive an agent on another box.
- \`vm-snapshot\` - flush agent state to persistent storage now (it also runs
  every 5 minutes and on shutdown).
- \`~/shared\` - a directory every VM in the fleet can read and write.

$docker_section## What persists

\`~/workspace\` is written straight through to network storage. Agent state
(\`~/.claude\`, \`~/.codex\`, \`~/.moerae\`, herdr layout) is snapshotted to it.
Everything else - including anything in \`/tmp\` or installed outside those
paths - is gone on the next deploy.
$END
BLOCK
)"

if [ -f "$DOC" ] && grep -qF "$BEGIN" "$DOC"; then
  # Drop the old block, keep everything the operator wrote around it.
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$DOC" > "$DOC.tmp"
  { cat "$DOC.tmp"; printf '%s\n' "$block"; } > "$DOC"
  rm -f "$DOC.tmp"
  log "toolbelt notes refreshed in ~/.claude/CLAUDE.md"
else
  [ -s "$DOC" ] && printf '\n' >> "$DOC"
  printf '%s\n' "$block" >> "$DOC"
  log "toolbelt notes written to ~/.claude/CLAUDE.md"
fi
