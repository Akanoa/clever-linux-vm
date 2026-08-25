---
name: vm-agent
description: Provision and drive a fleet of long-lived coding agents (Claude Code, opencode, codex) on Clever Cloud VMs. Use when work should run somewhere that outlives this session - delegating a long task to another machine, running several agents in parallel, keeping a persistent dev box, or collecting results from agents running elsewhere.
metadata:
  author: Yannick Guern
  repository: https://github.com/Akanoa/clever-linux-vm
---

# vm-agent

A fleet of Clever Cloud VMs, each running [herdr](https://herdr.dev) with
coding agents inside tmux panes that keep working while nobody is
attached. `provision.sh` builds and maintains the fleet; `tools/fleet`
drives the agents on it over HTTP.

Use this skill to **delegate work that outlives a session**: a migration
that takes hours, several independent tasks in parallel, anything that
should survive your own context running out.

## Ask what the organisation costs before creating anything

Each VM is a separate Clever Cloud application. What that costs depends
entirely on the organisation it lands in — some carry free-tier credits, a
sponsorship or an open-source plan; others are billed by the hour. **The
API will not tell you which**, and guessing wrong in either direction is
unhelpful: nagging about cost on a covered organisation is noise, and
quietly starting eight VMs on a billed one is worse.

So ask, once, before the first VM:

> Is `<org>` on a free tier or covered by credits, or is it billed?

* **Covered** — size and count are a technical decision. Run as many
  agents as the work actually wants, and leave them up between sessions.
* **Billed** — say what you are about to create before creating it, prefer
  fewer and smaller VMs, and offer teardown once the work is collected.

Either way, never scale a fleet up silently. And if the work fits in the
session you are already in, just do it here.

## Where you are matters

| | |
|---|---|
| **On a laptop / workstation** | `provision.sh` builds the fleet. `tools/fleet` reads `.secrets/fleet.env`. |
| **On a VM in the fleet** | `fleet` is already on `PATH` and configured from the shared config provider. Agents can drive each other. `provision.sh` is not usable here. |

Check with `echo "$VM_AGENT_NAME"` — set on a VM, empty on a laptop.

## Creating a fleet

**`./new-fleet.sh` is interactive and refuses to run without a terminal.**
It exits with *"no terminal on stdin"* when piped. Do not try to feed it
answers — ask the user to run it themselves, in their own terminal:

> Run `./new-fleet.sh` — it asks for the organisation, a fleet name, your
> commit identity, the agent and forge tokens, and how many VMs you want.

Everything after that first run is non-interactive and yours to drive:

```bash
./provision.sh web-agent               # create or update one VM
./provision.sh agent --count 4         # agent-1 .. agent-4
./provision.sh --all                   # re-apply to every VM in vms.txt
./provision.sh --list                  # what exists, and its real URL
./provision.sh --all --no-deploy       # apply config without pushing code
```

It is idempotent: every step checks the desired state first, so re-running
is a no-op and re-running after a failure resumes. A VM takes about two
minutes. `--flavor <size>` sizes them (`pico nano XS S M L XL 2XL 3XL`);
`fleet.conf` holds the lasting defaults.

Tokens go in `.secrets/tokens.env`, never on a command line:

```bash
./agent-tokens.sh                      # what is set, masked
./agent-tokens.sh set GH_TOKEN         # hidden prompt
./provision.sh --all --no-deploy       # push to the fleet
```

## Driving agents

```bash
fleet status                       # which VMs are up
fleet agents                       # every agent on every box
fleet start <vm> <name> [kind]     # launch one in a fresh pane
fleet task <vm>/<name> "..."       # give it work, collect the answer
fleet fetch <vm>/<name>            # read that answer
fleet read <vm>/<name> [-f]        # recent terminal output, -f to follow
fleet prompt <vm>/<name> "..."     # a bare prompt, no result collection
fleet keys <vm>/<name> esc         # unblock one waiting on a keypress
```

`kind` defaults to `claude`; `codex`, `opencode`, `gemini`, `cursor` and
seventeen others are accepted (the endpoint lists them all if you
guess wrong). A fourth argument sets the working
directory.

A normal delegation is three calls:

```bash
fleet start agent-1 migrate
fleet task agent-1/migrate "Port src/legacy/*.js to TypeScript. Run the tests."
# ... later ...
fleet fetch agent-1/migrate
```

### Collect results as files, never off the terminal

Agent UIs **collapse tool output**: a listing the remote agent printed
comes back through `fleet read` as `Ran 1 shell command` — summary intact,
data gone. `fleet read` is for watching progress, not for getting answers.

`fleet task` handles this by appending an instruction to write the answer
to `~/out/<name>.md`, which lives on the shared bucket and is served back
by `fleet fetch`. Use `task`/`fetch` whenever you need the output.

`fleet out <vm>` lists what a VM has produced.

## Storage

* `~/workspace` → the shared FS Bucket, per-VM subtree. Repos and
  uncommitted work go here; it survives redeploys.
* `~/shared` → visible to every VM in the fleet.
* Agent state (`~/.claude`, `~/.codex`, …) is on local disk and rsync'd to
  the bucket every 5 minutes and on clean shutdown. Run `vm-snapshot`
  before a deliberate restart if you just re-authenticated something.
* **Large files go to Cellar, not the bucket**: `cellar put ./big.parquet
  data/`, `cellar get`, `cellar url` (presigned, 1h). The bucket is NFS —
  sqlite, sockets and lock files misbehave on it.
* Nothing outside those paths survives a redeploy. `~/.local/bin` is
  rebuilt on every boot.

## Constraints worth knowing before you hit them

* **Only port 8080 is routed** between instances — not even on the private
  address. That is why the fleet talks over each VM's health endpoint
  rather than SSH or a custom port.
* **herdr has no federation.** `--remote` takes exactly one target;
  `tools/fleet` exists to fill that gap.
* **Unattended agents need `bypassPermissions`.** `acceptEdits` re-prompts
  on every novel command and wedges a pane with nobody at the keyboard.
  The VMs hold forge tokens and a push-capable commit key — that is the
  trade, and the user makes it in `fleet.conf`.
* **No root, no package manager.** Use `mise` for extra runtimes.
* **The shared add-ons are found by name.** Changing `FLEET_NAME` or the
  `*_ADDON` values does not move storage, it abandons it: the old add-ons
  keep billing where nothing will look for them again. Purge before
  renaming, not after.

## Tearing down

Whether idle VMs cost anything depends on the organisation — see above.
On a billed one, offer teardown once results are collected; on a covered
one, leaving the fleet up is usually what the user wants.

Destroying the applications leaves the Cellar bucket, the FS Bucket and
the config provider running — they are fleet-wide, so no single teardown
may take them.

```bash
./provision.sh --destroy agent-3 --yes           # one VM
./provision.sh --destroy --all --yes             # every VM; storage stays
./provision.sh --destroy --all --purge --yes     # ... and the storage too
```

`--purge` destroys everything the agents stored. Confirm with the user
before using it, and prefer the plain form if the work might be wanted
again.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `fleet` says *no roster* | No fleet yet, or `.secrets/fleet.env` missing. Run `./provision.sh --all`. |
| A destroyed VM shows as unreachable | A stale `VM_AGENT_FLEET` exported in the shell. The file wins now, and says so. |
| VM reachable, agent never answers | It is blocked on a prompt. `fleet read` to see it, `fleet keys` to answer. |
| `fleet fetch` 404s | The agent has not written `~/out/<name>.md` yet, or ignored the instruction. Check with `fleet read`. |
| Deploy refuses | An agent is mid-task. `--force` overrides and kills its pane. |
| Adding a VM refuses because agents on *other* VMs are busy | The new name changes `VM_AGENT_FLEET`, and publishing it restarts every linked app. `--no-roster` creates and deploys the new VM without republishing, leaving the busy ones alone; re-run without it later to publish. |
| Agent has no model access | No `CLAUDE_CODE_OAUTH_TOKEN` on the fleet. `./agent-tokens.sh claude`. |
| An agent is listed but `prompt`/`keys` fail with *not an active named agent* | Something stamped a **reported agent label** on its pane (darwin does this when it takes one over). herdr treats that label as authoritative over its own live detection, and only *detected* agents accept input. `fleet read` still works. |
| An agent vanishes from `fleet agents` entirely | Its pane lost its `name`. **`herdr pane release-agent` clears the reported stamp and the name with it** — the session keeps running, but an unnamed, undetected pane is invisible to the fleet API, so a live agent looks dead. Re-add it with `herdr agent rename <pane-id> <name>` (positional target first). |
| A pane darwin spawned has no name at all | darwin calls `pane report-agent` (a label) but not `agent rename` (a name), so its panes are born nameless and unreachable from off the machine. |

Read `README.md` in the repository root for the reasoning behind any of
this, and `./provision.sh --help` / `fleet --help` for the full option
lists.
