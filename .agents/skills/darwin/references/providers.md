# Providers, models and custom CLIs

Each role is configured independently. Nothing in darwin is tied to a particular
vendor: a role is "a command that reads a brief and edits files in a directory".

## Configuration

`darwin.config.json` at the repository root (see `darwin.config.example.json`):

```json
{
  "agents": {
    "implementer": { "provider": "claude", "model": "claude-opus-5", "timeout_sec": 3600 },
    "reviewer":    { "provider": "codex",  "model": "gpt-5",         "timeout_sec": 3600 }
  }
}
```

Precedence: CLI flags > `DARWIN_*` environment variables > `darwin.config.json`
> defaults. The resolved config is frozen into `run.json` at `init`, so a run
keeps behaving the same way even if the file changes underneath it.

```bash
DARWIN_IMPL_PROVIDER=claude DARWIN_IMPL_MODEL=claude-opus-5 \
DARWIN_REVIEWER_PROVIDER=gemini DARWIN_REVIEWER_MODEL=gemini-2.5-pro \
  $DARWIN init --task "..."
```

**Use different providers, or at least different models, for the two roles.**
The reviewer exists to see what the implementer could not. Two instances of one
model share their blind spots, and a review that agrees for the wrong reason is
worse than no review.

## Built-in provider templates

Headless, non-interactive invocations. Every one of them ends up as
`<bin> <args> [--model <model>] "<bootstrap>"`, where the bootstrap tells the
agent to read `.darwin/PROMPT.md` in its working directory.

| provider | command |
|---|---|
| `claude` | `claude -p --dangerously-skip-permissions --model <model> "<bootstrap>"` |
| `codex` | `codex exec --full-auto --model <model> "<bootstrap>"` |
| `gemini` | `gemini -y -p -m <model> "<bootstrap>"` |
| `opencode` | `opencode run -m <model> "<bootstrap>"` |
| `cursor` | `cursor-agent -p --force --model <model> "<bootstrap>"` |
| `amp` | `amp -x "<bootstrap>"` |
| `crush` | `crush run -q -m <model> "<bootstrap>"` |
| `inline` | nothing is spawned; you drive the role yourself |

These flags are what the CLIs accept today, and CLIs change. `darwin doctor`
tells you whether the binary exists; if a flag has moved, override the whole
command rather than waiting for a fix:

```json
{ "agents": { "reviewer": {
    "provider": "custom",
    "cmd": ["my-agent", "--model", "{model}", "--headless", "{prompt}"],
    "model": "some-model"
} } }
```

`{model}` and `{prompt}` are substituted. Omit `{prompt}` and the brief is piped
on stdin instead. The command runs with its working directory set to the role's
worktree, so relative paths in the brief resolve.

The agents also get `DARWIN_RUN_DIR`, `DARWIN_ROLE`, `DARWIN_ROUND` and
`DARWIN_WORKTREE` in the environment when they run as subprocesses.

## Permissions

Each role runs unattended in a throwaway worktree, which is why the templates
use each CLI's non-interactive mode. That trade is deliberate — the isolation is
what makes it acceptable — but it is your call: point `cmd` at a sandboxed
wrapper if the repository warrants it.

## `inline`: no agent CLI at all

```json
{ "agents": { "implementer": { "provider": "inline" } } }
```

Then render the brief and hand it to a subagent of your own harness:

```bash
$DARWIN prompt --role implementer --round 1 --out /tmp/brief.md
```

Set that subagent's working directory to the role's worktree. Everything else in
the workflow is unchanged, because capture, measurement, verification and
judgement all run through the CLI against files in the run directory — not
through whatever produced the code.

## Where the agent actually runs

- **herdr present** — the role's worktree is a herdr workspace, and the agent
  runs in its persistent root pane. It survives a closed laptop, you can watch it
  live, and darwin reports the role's state (`working`, `idle`, `blocked`) into
  the herdr UI. Completion is detected by a nonce-tagged sentinel the shell
  prints after the agent exits, and the exit code is read from it.
- **no herdr** — the agent runs as a plain subprocess in the worktree with output
  captured to `agent.log`.

`clean` closes the workspaces darwin opened — the role workspaces and, if herdr
had to open one for the source repository, that one too — so repeated runs do not
leave a trail behind in the herdr UI.

Force one or the other with `"spawn": "herdr" | "subprocess"` (default `auto`).
A herdr failure always falls back to a subprocess rather than losing the round.
