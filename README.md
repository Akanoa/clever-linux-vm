# vm-agent

A long-lived development box on Clever Cloud's `linux` runtime, running
[herdr](https://herdr.dev) so that Claude Code, opencode and codex keep
working while nobody is attached.

| | |
|---|---|
| App | `vm-agent` (`app_<id>`) |
| Runtime | `linux` (Exherbo, user `bas`, **no root, no package manager**) |
| Flavor | M — 4 vCPU / 4 GB |
| Persistence | FS Bucket `vm-agent-fs` mounted at `$APP_HOME/persistent` |
| Object storage | Cellar `vm-agent-cellar`, bucket `vm-agent-files` |
| Health | `https://app-<id>.cleverapps.io/status` |

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

Each VM gets its own application, its own FS Bucket and its own Cellar
add-on (`--cellar <name>` reuses a shared one instead). They share a single
git-commit key at `.secrets/id_ed25519`, so the public key only has to be
registered on the forges once; `--per-vm-key` gives each box its own.

Options: `--flavor` (default `M`), `--region` (default `par`),
`--no-deploy`, `--key <path>`.

Tokens come from `.secrets/tokens.env` (gitignored) or the surrounding
environment. **An empty local token never overwrites one already stored on
an app** — so running `--all` without secrets in your shell is safe.

`vms.txt` is the fleet registry and is committed; `.secrets/` is not.

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

* **`~/workspace` → symlinked onto the bucket.** Repos and uncommitted work
  are written through immediately. Slightly slower than local disk; worth
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

Set them with:

```bash
clever env set GH_TOKEN "ghp_..."      --app vm-agent
clever env set GITLAB_TOKEN "glpat_..." --app vm-agent
clever restart --app vm-agent
```

The commit key is installed to `~/.ssh/id_ed25519` at boot, GitHub and
GitLab host keys are pre-seeded into `~/.ssh/known_hosts`, and `~/.ssh/config`
pins the key for every host.

### Current state

* **GitLab** — `GITLAB_TOKEN` set, `glab` authenticated as `<forge-user>`. The
  public key is registered on the account as *vm-agent (Clever Cloud)* with
  `usage_type=auth_and_signing`, and `GIT_SIGN_COMMITS=true`, so commits
  made on the box show as Verified.
* **GitHub** — `GH_TOKEN` is still empty. Set it, then add the same public
  key at <https://github.com/settings/keys> (as both an authentication and
  a signing key) for SSH pushes and verified commits.

The public key:

```
ssh-ed25519 <public key> vm-agent@clever-cloud
```

`GIT_USER_EMAIL` is `you@example.com` — the only address verified on the
GitLab account, which is what signature verification matches against.

## Layout

```
boot.sh                    orchestrator: health first, then provisioning
scripts/lib.sh             shared helpers
scripts/health-server.py   status endpoint on :8080 (required by the runtime)
scripts/00-persist.sh      FS Bucket wiring + state restore
scripts/10-secrets.sh      SSH key, git identity, gh/glab, Cellar
scripts/20-toolchain.sh    installs the agents, herdr, gh, glab
scripts/30-shell.sh        makes `clever ssh` sessions match the boot env
scripts/40-herdr.sh        starts the headless herdr server
bin/cellar                 s3cmd wrapper for the Cellar bucket
bin/vm-snapshot            agent state -> FS Bucket
provision.sh               idempotent fleet provisioner (runs locally)
connect.sh                 local helper: ssh / herdr attach
vms.txt                    fleet registry
```

## Debugging

```bash
curl https://app-<id>.cleverapps.io/status
curl https://app-<id>.cleverapps.io/logs
clever logs --app vm-agent
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
