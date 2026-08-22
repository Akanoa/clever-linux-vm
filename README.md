# vm-agent

A long-lived development box on Clever Cloud's `linux` runtime, running
[herdr](https://herdr.dev) so that Claude Code, opencode and codex keep
working while nobody is attached.

| | |
|---|---|
| Runtime | `linux` (Exherbo, user `bas`, **no root, no package manager**) |
| Default flavor | M — 4 vCPU / 4 GB |
| Persistence | one FS Bucket for the fleet, mounted at `$APP_HOME/persistent` |
| Object storage | one Cellar bucket for the fleet |
| Instances | pinned to 1 per app — scale out by adding VMs, not instances |
| Health | `https://app-<id>.cleverapps.io/status` — `./provision.sh --list` prints the real URLs |

## Provisioning a VM

`provision.sh` is idempotent: every step checks the desired state before
touching anything, so re-running it is a no-op and re-running after a
partial failure resumes where it stopped.

```bash
./provision.sh web-agent               # create or update one VM, then deploy
./provision.sh agent --count 4         # agent-1 .. agent-4, running in parallel
./provision.sh --all                   # re-apply to every VM in vms.txt
./provision.sh --list                  # fleet overview
./provision.sh --destroy agent-3 --yes # tear one down, add-ons included
```

Each VM gets its own application. Storage is **shared across the fleet** —
one Cellar add-on and one FS Bucket, linked to every app — because N idle
add-ons per VM is pure waste:

```
persistent/                  the one FS Bucket, mounted on every VM
├── vms/
│   ├── web-agent/{workspace,state}
│   └── api-agent/{workspace,state}
└── shared/                  → ~/shared on every box
```

Each VM is confined to `vms/$VM_AGENT_NAME`, so `vm-snapshot`'s
`rsync --delete` can never reach another box's state. `~/shared` is the one
place they meet on purpose. Cellar needs no such split — S3 is
concurrent-safe, so the fleet shares one bucket.

**Apps are pinned to a single instance.** A vm-agent is a pet: its herdr
server, workspace and agent state live on one box, and two instances of the
same app would share `VM_AGENT_NAME` and fight over the same subtree — NFS
here mounts `local_lock=all`, so there is no cross-instance lock to arbitrate.
Scale out with `--count`, never with `clever scale --instances`.

Everything the fleet has in common lives in a single free **Configuration
provider** add-on, `vm-agent-config`, linked to every app:

| Shared (config provider) | Per-VM (app env) |
|---|---|
| `VM_AGENT_SSH_KEY_B64` | `CC_FS_BUCKET` |
| `GH_TOKEN`, `GITLAB_TOKEN`, `GITLAB_HOST` | `CELLAR_BUCKET` |
| `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_SIGN_COMMITS` | `VM_AGENT_NAME` |
| `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` | |
| `OPENAI_API_KEY`, `OPENROUTER_API_KEY` | |

So a token is rotated in one place and every box picks it up — Clever Cloud
restarts the linked applications automatically. Values set directly on an
app would shadow the provider, so `provision.sh` removes them from the app
env when it takes ownership of a key.

`--per-vm-key` opts out of the shared commit key and generates one per box,
kept in the app's own env instead. `--cellar` / `--fs` point the fleet at
differently-named storage add-ons.

If an app has a *stray* storage add-on linked — a per-VM leftover from
before storage was shared — `provision.sh` warns: it would silently win the
`/persistent` mount over the bucket `CC_FS_BUCKET` names.

Fleet-wide settings live in `fleet.conf`: commit identity, signing, GitLab
host, default flavor and region. Start from the template:

```bash
cp fleet.conf.example fleet.conf
```

It is gitignored, because it carries your name and email. An environment
variable of the same name overrides it, so a one-off
`FLAVOR=L ./provision.sh big-agent` still works.

Options: `--flavor`, `--region`, `--config <addon-name>`,
`--cellar <addon-name>`, `--key <path>`, `--per-vm-key`, `--no-deploy`,
`--forget <VAR>`.

Tokens come from `.secrets/tokens.env` (gitignored) or the surrounding
environment. **An empty local token never blanks one already in the
provider** — it is read back and kept, so running `--all` without secrets
in your shell is safe.

**Deploying restarts every VM**, which destroys herdr panes and kills
whatever agents were mid-task — a write to the shared config does the same,
since Clever Cloud restarts linked apps on change. `provision.sh` refuses
when any agent is `working` or `blocked`; `--force` overrides.

`--destroy` removes an app and its own two add-ons, never the shared
provider.

Nothing account-specific is tracked: `.clever.json`, `fleet.conf`,
`vms.txt` and `.secrets/` are all gitignored, so this repository is safe to
publish.

## Agent tokens

`agent-tokens.sh` fills `.secrets/tokens.env`; `provision.sh` pushes it to
the config provider, and every linked VM restarts with the new value.

```bash
./agent-tokens.sh                      # what is set, masked
./agent-tokens.sh claude               # run `claude setup-token`, store the result
./agent-tokens.sh set OPENAI_API_KEY   # hidden prompt for any supported key
./provision.sh --all --no-deploy       # apply to the fleet
```

Removing a secret needs `--forget`, because an empty local value means
"keep whatever the provider has" rather than "delete it":

```bash
./agent-tokens.sh unset OPENAI_API_KEY
./provision.sh --all --no-deploy --forget OPENAI_API_KEY
```

How each agent picks its credentials up:

| Agent | Mechanism |
|---|---|
| `claude` | reads `CLAUDE_CODE_OAUTH_TOKEN`, else `ANTHROPIC_API_KEY`, else the restored session |
| `opencode` | reads `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `OPENROUTER_API_KEY` |
| `codex` | keeps credentials in a file, so boot runs `codex login --with-api-key` when `OPENAI_API_KEY` is set |

`claude setup-token` needs a Claude subscription and issues one long-lived
token that serves the whole fleet — unlike copying `~/.claude/.credentials.json`,
which would make every VM refresh the same OAuth session and invalidate
each other.

Interactive `claude auth login`, `codex login` and `opencode auth login`
inside a box still work, and the state snapshot carries them across
restarts. `/status` reports what each agent found:

```json
"agent_auth": { "claude": "subscription-token", "codex": null, "opencode": ["anthropic"] }
```

## Demo

`demo.sh` provisions a VM, sets the fleet to run agents unattended, and
opens a two-pane layout: control on the left, the remote herdr UI on the
right.

```bash
./demo.sh start [vm-name]    # provision if needed, then open the layout
./demo.sh layout [vm-name]   # just open the layout
./demo.sh stop [vm-name]     # destroy the VM, restore the permission mode
```

It edits nothing: tmux runs on its own socket with its own prefix, so your
`~/.tmux.conf` is untouched, and the permission mode is passed as an
environment override that `fleet.conf`'s `: "${VAR:=default}"` already
honours.

The prefix matters — **both herdr instances bind `ctrl+b`**, so the demo
tmux uses `ctrl+a` and leaves `ctrl+b` to the remote herdr on the right.
Detach the whole thing with `ctrl+a d`.

## Fleet federation

herdr has no federation — `herdr --remote` errors with *"can only be
specified once"* — and Clever Cloud routes **no port but 8080** between
instances, not even on the private address (verified: a listener on 4040
is unreachable both ways). So the health server doubles as the inter-VM
channel, over the URL the platform already publishes.

```bash
fleet status                       # one line per VM
fleet agents                       # every agent on every box
fleet start <vm> <name> [kind]     # launch an agent in a fresh pane
fleet prompt <vm>/<name> "..."     # submit a prompt
fleet read <vm>/<name> [-f]        # recent terminal output, -f to follow
fleet attach <vm>[/<name>]         # attach the remote herdr UI, focusing that agent
fleet keys <vm>/<name> 1           # answer a prompt the agent is blocked on
fleet task <vm>/<name> "..."       # prompt, and collect the answer to a file
fleet fetch <vm>/<name>            # print that file
fleet out <vm>                     # list a VM's result files
```

### Getting results back

Do not read results off the terminal. Agent UIs **collapse tool output** —
a listing the agent printed comes back as `Ran 1 shell command`, summary
intact and data gone. `fleet task` instead asks the agent to write its
answer to `~/out/<name>.md`, which lives on the shared FS Bucket (so it
survives redeploys and any VM can read it) and is served by the endpoint.

```bash
fleet task vm-agent-2/gitlab "list all my GitLab projects with pagination"
fleet fetch vm-agent-2/gitlab
```

It runs on the VMs (agents can drive each other) and on your laptop, where
`provision.sh` writes the roster and token to `.secrets/fleet.env`.

| Endpoint | |
|---|---|
| `GET /` | unauthenticated — the platform's health probe |
| `GET /status`, `/logs` | |
| `GET /agents`, `/agents/<n>`, `/agents/<n>/read` | |
| `POST /agents` | create a pane and launch an agent |
| `POST /agents/<n>/prompt`, `/agents/<n>/keys` | |

Everything but `/` needs `Authorization: Bearer $VM_AGENT_FLEET_TOKEN`,
minted by `provision.sh` into the config provider. It **fails closed**: with
no token configured nothing but `/` answers, so a half-provisioned box never
exposes its logs to the internet.

### Why agents in panes need seeding

A pane agent has nobody at the keyboard, so anything that waits for input
wedges it. `CLAUDE_CODE_OAUTH_TOKEN` authenticates headless `claude -p` but
does **not** suppress the interactive gates, so boot seeds them:

* `hasCompletedOnboarding` — otherwise the TUI stops at the login selector
* per-directory `hasTrustDialogAccepted` — otherwise the folder-trust prompt
* `permissions.defaultMode` from `CLAUDE_PERMISSION_MODE`
* herdr's own `onboarding = false`, or it greets whoever attaches
* the one-time bypass-permissions warning, cleared by the endpoint when
  `CLAUDE_PERMISSION_MODE=bypassPermissions` — turning the gate off
  introduces a gate of its own

`acceptEdits` is not enough for unattended work: every *novel* command
re-prompts, including "contains shell syntax that cannot be statically
analyzed". Autonomous agents need `bypassPermissions`.

The first two live in `~/.claude.json` — a *file*, not the `~/.claude`
directory — which is why it is snapshotted separately from the state dirs.

## Connecting

```bash
clever ssh --alias <vm-name>   # opens a shell on the running instance
herdr                          # attach to the persistent session
```

`ctrl+b q` detaches and leaves every agent running. From a laptop that has
herdr installed you can also attach the whole UI over SSH — see
`connect.sh`, which resolves the instance's current address:

```bash
./connect.sh --herdr
```

## What is installed

Provisioned on every boot into `~/.local/bin` (nothing survives a redeploy
except the FS Bucket, so this is re-run each time — it takes ~60s):

`herdr`, `claude`, `opencode`, `codex`, `gh`, `glab`, plus the `cellar` and
`vm-snapshot` helpers.

Already in the base image: `git`, `node` 24, `bun`, `cargo`/`rustc`,
`python3`, `mise`, `tmux`, `zsh`, `jq`, `rg`, `fd`, `rsync`, `s3cmd`.

Use `mise` for anything else (`mise use -g go@latest`) — there is no `sudo`
and no `apt` on this runtime.

## Storage model

Two different mechanisms, because the FS Bucket is NFS-backed:

* **`~/workspace` → symlinked into `vms/$VM_AGENT_NAME/workspace` on the
  bucket.** Repos and uncommitted work are written through immediately. Slightly slower than local disk; worth
  it, since this is the data you cannot lose.
* **Agent state → local disk, rsync'd to the bucket** every 5 minutes, on
  clean shutdown, and whenever you run `vm-snapshot`. These directories
  (`~/.claude`, `~/.codex`, `~/.config/opencode`, `~/.config/herdr`,
  `~/.config/gh`, `~/.config/glab-cli`) contain unix sockets, lock files and
  sqlite databases, none of which behave over NFS.

Run `vm-snapshot` by hand before a deliberate `clever restart` if you have
just re-authenticated an agent and do not want to redo it.

**Big files go to Cellar**, not the bucket:

```bash
cellar put ./dataset.parquet datasets/   # upload
cellar ls datasets/
cellar get datasets/dataset.parquet
cellar url datasets/dataset.parquet      # presigned link, 1h
```

`~/.s3cfg` and `~/.aws/{config,credentials}` are written at boot, so
`s3cmd`, `aws` and any boto3/aws-sdk code point at Cellar out of the box.

## Secrets

| Variable | Purpose |
|---|---|
| `VM_AGENT_SSH_KEY_B64` | base64 of the OpenSSH private key used for git |
| `GH_TOKEN` | GitHub CLI + HTTPS pushes |
| `GITLAB_TOKEN` | GitLab CLI |
| `GITLAB_HOST` | defaults to `gitlab.com`; set for self-hosted |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | commit identity |
| `GIT_SIGN_COMMITS` | `true` to SSH-sign every commit |

All of these are fleet-wide, so set them once in `.secrets/tokens.env` (or
your shell) and re-run the provisioner:

```bash
echo 'export GH_TOKEN="ghp_..."' >> .secrets/tokens.env
./provision.sh --all --no-deploy
```

Every linked VM restarts with the new value. `clever env set --alias <vm>`
still works for a genuinely per-box override, but the next `provision.sh`
run will remove it again for any key the provider owns.

The commit key is installed to `~/.ssh/id_ed25519` at boot, GitHub and
GitLab host keys are pre-seeded into `~/.ssh/known_hosts`, and `~/.ssh/config`
pins the key for every host.

### Registering the key on your forges

`provision.sh` prints the public key when it finishes. Add it as **both**
an authentication and a signing key:

* **GitHub** — <https://github.com/settings/keys>
* **GitLab** — the CLI can do it once `GITLAB_TOKEN` is set:

  ```bash
  glab api --method POST /user/keys \
    -f "title=vm-agent (Clever Cloud)" \
    -f "key=$(cat .secrets/id_ed25519.pub)" \
    -f usage_type=auth_and_signing
  ```

Set `GIT_USER_EMAIL` in `fleet.conf` to an address **verified on the
forge** — that is what signature verification matches against, and an
unverified address makes every signed commit show up as unverified.

## Layout

`scripts/` runs unattended during boot and is called by full path;
`tools/` is installed into `~/.local/bin` for you to type at a prompt.
Everything here is bash, apart from the Python status server.

```
boot.sh                    orchestrator: health first, then provisioning
scripts/lib.sh             shared helpers
scripts/health-server.py   status endpoint on :8080 (required by the runtime)
scripts/00-persist.sh      FS Bucket wiring + state restore
scripts/10-secrets.sh      SSH key, git identity, gh/glab, Cellar
scripts/15-agent-auth.sh   agent credentials (claude / codex / opencode)
scripts/20-toolchain.sh    installs the agents, herdr, gh, glab
scripts/30-shell.sh        makes `clever ssh` sessions match the boot env
scripts/40-herdr.sh        starts the headless herdr server
tools/cellar               s3cmd wrapper for the Cellar bucket
tools/vm-snapshot          agent state -> FS Bucket
tools/fleet                talk to the other VMs (runs on VM and laptop)
provision.sh               idempotent fleet provisioner (runs locally)
agent-tokens.sh            fills .secrets/tokens.env (runs locally)
fleet.conf.example         template for fleet.conf (gitignored)
connect.sh                 local helper: ssh / herdr attach
vms.txt                    fleet registry (gitignored)
```

## Debugging

```bash
./provision.sh --list                 # prints each VM's status URL
curl https://app-<id>.cleverapps.io/status
curl https://app-<id>.cleverapps.io/logs
clever logs --alias <vm-name>
```

Inside the box, `vm-status` and `vm-log` are aliases for the same thing.
The boot script never aborts on a failed step: a half-provisioned instance
you can SSH into is more useful than a dead one.

One quirk worth knowing: the stock `~/.bashrc` stops part-way through in
*non-interactive* shells, so `clever ssh < script.sh` gets neither the app
environment nor `~/.local/bin`. Interactive sessions are fine. Scripts
should start with:

```bash
. ~/.vm-agent-rc
```
