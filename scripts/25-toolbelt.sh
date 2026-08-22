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

**The one thing to get right:** every \`put\` *without* \`-c\` starts a new
conversation, and a \`search\` without \`-c\` only looks at the newest one. Keep
the conversation id from your first \`put\` and pass it to every later \`put\`
and \`search\`, or your memory is write-only. \`--project-scope\` searches across
conversations, but only reaches segments that have been promoted, so it is
not a substitute early on.

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

## What persists

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
