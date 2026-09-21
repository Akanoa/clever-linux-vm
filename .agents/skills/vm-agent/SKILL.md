---
name: vm-agent
description: Provision and drive a fleet of long-lived coding agents (Claude Code, opencode, codex) on Clever Cloud VMs. Use when work should run somewhere that outlives this session - delegating a long task to another machine, running several agents in parallel, keeping a persistent dev box, or collecting results from agents running elsewhere. Also covers creating a Clever Cloud Kubernetes cluster for the fleet and spawning disposable agents into it as pods, and giving those VMs a working Docker daemon for Testcontainers, which the runtime cannot provide itself.
metadata:
  author: Yannick Guern
  repository: https://github.com/Akanoa/clever-linux-vm
---

# vm-agent

A fleet of Clever Cloud VMs, each running [herdr](https://herdr.dev) with
coding agents inside tmux panes that keep working while nobody is
attached. `provision.sh` builds and maintains the fleet; `tools/fleet`
drives the agents on it over HTTP.

The same fleet can also drive a Clever Cloud **Kubernetes cluster**, where
an agent is a pod rather than a box: seconds to start, nothing kept,
thrown away once it has answered. `cluster.sh` builds that side and
`tools/swarm` drives it, with the same verbs `fleet` uses.

Use this skill to **delegate work that outlives a session**: a migration
that takes hours, several independent tasks in parallel, anything that
should survive your own context running out. Two shapes, chosen by
lifetime — a VM to come back to, a pod to throw away.

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

**A Kubernetes cluster is a bigger commitment than a VM.** The control
plane bills from the moment it exists, whether or not a pod is running,
and no `provision.sh` teardown removes it. Ask before creating one, and
say plainly that only `./cluster.sh destroy --yes` takes it back.

## Where you are matters

| | |
|---|---|
| **On a laptop / workstation** | `provision.sh` builds the VM fleet, `cluster.sh` builds the Kubernetes side. `fleet` and `swarm` read `.secrets/fleet.env` and `.secrets/k8s.env`. |
| **On a VM in the fleet** | `fleet` and `swarm` are on `PATH`, configured from the shared config provider. Agents can drive each other, and can spawn pods. `provision.sh` and `cluster.sh` are **not** usable here. |

Check with `echo "$VM_AGENT_NAME"` — set on a VM, empty on a laptop.

Creating infrastructure is a laptop job either way: a VM has no Clever API
credentials, on purpose, so it can use the fleet and the cluster but not
grow or delete either.

## Creating a fleet

Everything a fleet needs lives in four gitignored files: `fleet.conf`
(settings), `.secrets/tokens.env` (tokens), `.secrets/id_ed25519` (the
commit key) and `vms.txt` (the registry). `new-fleet.sh` is a wizard that
fills the first two by asking; **you can fill them directly instead**, and
then everything is yours to drive.

### If a human is at the keyboard

**`./new-fleet.sh` is interactive and refuses to run without a terminal.**
It exits with *"no terminal on stdin"* when piped. Do not try to feed it
answers — ask the user to run it themselves:

> Run `./new-fleet.sh` — it asks for the organisation, a fleet name, your
> commit identity, the agent and forge tokens, and how many VMs you want.

It is the better path when one is available: it validates the tokens
against the GitHub and GitLab APIs and registers the commit key on both
forges for you.

### If you are driving it yourself

The wizard is a convenience, not a gate. Given the tokens, these steps do
the same thing and are all non-interactive:

**1. Settings.** Copy the template and set the identity — `GIT_USER_EMAIL`
must be an address **verified on the forge**, or every signed commit shows
as unverified:

```bash
cp fleet.conf.example fleet.conf
# then edit: GIT_USER_NAME, GIT_USER_EMAIL, FLEET_NAME, CLEVER_ORG,
# CLAUDE_PERMISSION_MODE (bypassPermissions for unattended agents),
# and the three *_ADDON names if FLEET_NAME is not the default.
```

**2. Tokens.** Ask the user for them — never invent or guess one, and
never put one on a command line where it lands in shell history. `set`
reads stdin when stdin is not a terminal, which is how you pass one
without echoing it:

```bash
printf '%s' "$THE_TOKEN" | ./agent-tokens.sh set CLAUDE_CODE_OAUTH_TOKEN
printf '%s' "$THE_TOKEN" | ./agent-tokens.sh set GH_TOKEN
printf '%s' "$THE_TOKEN" | ./agent-tokens.sh set GITLAB_TOKEN
./agent-tokens.sh                      # confirm, masked
```

`CLAUDE_CODE_OAUTH_TOKEN` comes from `claude setup-token` on the user's
own machine (it needs a Claude subscription, and one token serves the
whole fleet). `ANTHROPIC_API_KEY` works instead. Without one of them the
VMs come up fine and the agents have no model access.

**3. Build it.** This generates the commit key, creates the three shared
add-ons, writes the shared config and deploys:

```bash
./provision.sh agent --count 2         # agent-1, agent-2
```

For a **pod-only fleet**, stop one step earlier — `./provision.sh
--shared-only` creates and publishes everything the agents share without
creating a box, and `./cluster.sh create` takes it from there.

**4. Register the commit key** — it is printed at the end of the run, and
git pushes fail until it is registered as **both** an authentication and a
signing key. With the tokens already in hand you can do this yourself:

```bash
gh ssh-key add .secrets/id_ed25519.pub --title vm-agent --type authentication
gh ssh-key add .secrets/id_ed25519.pub --title vm-agent --type signing
glab api --method POST /user/keys -f "title=vm-agent" \
  -f "key=$(cat .secrets/id_ed25519.pub)" -f usage_type=auth_and_signing
```

Re-running any of this is safe.

### Driving it afterwards

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

Rotating a token later is the same `agent-tokens.sh set`, followed by
`./provision.sh --all --no-deploy` to push it — which restarts every VM,
so check `fleet agents` for busy ones first.

## A second fleet — a local clone, not `git worktree`

"New fleet" for a **different project** means a second
`fleet.conf`/`vms.txt`/`.secrets`/`.clever.json`, not the same four
files reused — one more VM in the fleet you are *already* driving is
just `./provision.sh <name>` from where you already are, nothing new to
set up.

**Use `git clone` into `~/.fleets/<fleet>` — not `git worktree`, not a
sibling directory.** Worktree looks like the obvious fit, since all four
config files are gitignored and a worktree gets its own copies for
free, but it does not actually work: `clever-tools` cannot resolve HEAD
through a worktree's `.git` **file** pointer (confirmed live —
`clever deploy` fails with *"Could not find HEAD"*, `GIT_DIR`/
`GIT_WORK_TREE` overrides do not help either). A local `git clone`
sidesteps this at almost no extra cost: cloning from a local path
hardlinks the object store by default, so it is cheap, and it gives
`clever-tools` a real `.git` directory. `~/.fleets/` beats a sibling
directory next to whichever checkout you happened to run this from —
one predictable, checkout-independent place to look, not one that moves
with wherever vm-agent was cloned:

```bash
ls ~/.fleets/ 2>/dev/null                          # existing fleets, if any
git clone --branch <fleet> "$PWD" ~/.fleets/<fleet>   # new fleet
# branch doesn't exist yet? plain clone, then: git checkout -b <fleet>
cd ~/.fleets/<fleet> && ./new-fleet.sh
```

**`~/.fleets/<fleet>` *is* the tracking mechanism** — discoverable with a
plain `ls ~/.fleets/` from anywhere. Before touching a fleet you have not
driven yet this session, `ls ~/.fleets/` and `cd` into the matching one
first — every command for that fleet (`new-fleet.sh`, `provision.sh`,
`agent-tokens.sh`, `tools/fleet`) resolves its config relative to *its
own* script location, not wherever you were a moment ago.

A clone's `.git/config` is entirely its own, so — unlike worktrees —
there is no shared-remote collision to worry about: two fleets can both
have a VM named the same thing with no conflict.

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
fleet herdr <vm> <args>...         # any permitted herdr subcommand
fleet abort <vm>/<name>            # interrupt it; retract an order in flight
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

### Retracting an order

`prompt` queues *behind* the work in flight, so a correction does not stop
anything - the agent finishes the order you no longer want first. `fleet
abort` is the way back:

```bash
fleet abort agent-1/migrate
fleet abort agent-1/migrate --tell "cancelled - revert what you changed under src/"
```

It sends `esc`, waits for the agent to leave `working`, and sends a second
`esc` if the first was swallowed. **Exit 0 once it is no longer working,
exit 1 if it could not be stopped** - branch on that rather than on the
text. Aborting an idle agent is a safe no-op.

The pane survives deliberately: killing the agent would take its context and
uncommitted work with it, and an interrupted one accepts a new order at once.
It does *not* revert the working tree - use `--tell` to ask for that - and it
cannot delete the result file of the cancelled order, so `fleet fetch` may
still return the previous answer; `abort` warns when that file exists.

### Collect results as files, never off the terminal

Agent UIs **collapse tool output**: a listing the remote agent printed
comes back through `fleet read` as `Ran 1 shell command` — summary intact,
data gone. `fleet read` is for watching progress, not for getting answers.

`fleet task` handles this by appending an instruction to write the answer
to `~/out/<name>.md`, which lives on the shared bucket and is served back
by `fleet fetch`. Use `task`/`fetch` whenever you need the output.

`fleet out <vm>` lists what a VM has produced.

## Agents in Kubernetes

The fleet has a second shape. A VM is a pet — two minutes to boot while it
installs its toolchain, a workspace on a bucket, a herdr session worth
reattaching to tomorrow. A **pod** is the opposite: seconds to start from a
prebuilt image, nothing on its filesystem meant to survive, no reason to
look at it again once it has answered.

**Choose by lifetime, not by size.** Work that fans out and is thrown away
— review these twelve files, try this refactor three ways, run this
migration on each of eight repos — belongs in pods. Work you want to come
back to, that needs a real workspace, or that needs Docker, belongs on a
VM.

`swarm` is to pods what `fleet` is to VMs, and deliberately uses the same
verbs. Check whether this fleet has a cluster at all with `swarm ls` (it
says so plainly if not).

```bash
swarm run <name> "the whole task, in one prompt"   # a Job: answers, then vanishes
swarm run <name> "..." --repo <git-url> --wait     # clone first, block for the answer
swarm fetch <name>                                 # the answer
swarm ls                                           # what is running
swarm kill <name>                                  # stop one
```

**`swarm run` is the default choice.** It is a Kubernetes Job running the
agent headless (`claude -p`, `codex exec`, `opencode run`): prompt in the
environment, answer on stdout, pod reaped by its TTL. Because it is
headless, it does *not* have the problem `fleet task` works around — no
UI is collapsing tool output, so the answer comes back whole.

Fanning out is just a loop; they are independent and cost nothing to set up:

```bash
for m in auth billing search; do
  swarm run "review-$m" "Review src/$m for injection bugs. Be specific." --repo "$REPO"
done
swarm ls                      # watch them
swarm fetch review-auth       # collect, one at a time
```

`swarm start <name> [kind]` is the other shape — a long-lived pod with
herdr in it, for when you need to correct an agent mid-task. It launches
one agent called `main`, so `<name>` alone addresses it:

```bash
swarm start build --repo <url>
swarm prompt build "also update the changelog"
swarm read build -f
swarm abort build --tell "stop, wrong module"
swarm task build "..."   &&   swarm fetch build
```

Nothing reaps a `swarm start` pod. Kill it when the work is collected.

Both shapes take `--env NAME=VALUE` (repeatable) to override one variable
from the cluster's shared secret for that pod alone — `env` beats
`envFrom` in a pod spec. Use it rather than rewriting the secret when one
agent needs a different permission mode or model; the secret is read by
every agent in the cluster.

### What a pod does not have

* **No bucket, no `~/shared`, no VM workspace.** Results leave through git
  or through `~/out/`, which is copied to Cellar when the pod stops.
  `swarm fetch` reads the live pod, then the Job's log, then Cellar.
* **No Docker daemon** — that is `--dockerd` and a VM.
* **No cluster credentials.** A pod cannot spawn pods; the namespace's
  secret deliberately omits the kubeconfig.
* **`--repo <url>` is the only way in.** A pod with no `--repo` starts in
  an empty `~/workspace`.

### Creating the cluster

**The shared config comes first — not a VM.** A pod's credentials come
from the fleet's Configuration provider, and there is no second place to
get them, so `cluster.sh create` refuses (before creating anything) if
that add-on is missing. What it wants is the *add-on*, which is free and
needs no box:

```bash
./agent-tokens.sh claude       # or: set ANTHROPIC_API_KEY
./provision.sh --shared-only   # the shared add-ons and config, no VM
```

A fleet whose agents are all pods never has to create a VM at all. The FS
Bucket is skipped too — only a VM mounts one — so `--shared-only` leaves a
Configuration provider and a Cellar bucket and stops there.

**Do this from a laptop, not from a VM.** The VMs hold the kubeconfig,
which is enough to start and kill agent pods, but deliberately not Clever
API credentials. Creating and deleting clusters is a billing decision and
stays where a person is. `echo "$VM_AGENT_NAME"` tells you where you are —
set on a VM, empty on a laptop.

**Ask about cost before creating one.** A control plane is the most
expensive thing in this repository and it bills whether or not a single
pod is running. The same question as for VMs — is this organisation on a
free tier or covered by credits, or is it billed? — and note that
`provision.sh --destroy --all --purge` does **not** remove the cluster.
`./cluster.sh destroy --yes` is the only thing that does.

Prerequisites, all on the machine you are running from:

| | |
|---|---|
| `clever login` done | `clever profile` succeeds |
| The shared config published | `./provision.sh --shared-only` (no VM needed) |
| An agent credential in it | or the pods start with no model access |
| Docker or podman | to build the image |
| `GITLAB_TOKEN` with `write_registry` | to push it — a **PAT**, not the OAuth token `glab auth login` stores |

Then, in order. Every step is idempotent and `--yes` makes it
non-interactive, so a partial failure is re-run rather than unpicked:

```bash
./cluster.sh create --yes     # 5-15 min: cluster, kubeconfig, namespace, secrets
./cluster.sh image --yes      # 5-10 min: build the image, push it to GitLab
./cluster.sh doctor           # checks the whole path, names the first gap
```

**Only if the fleet also has VMs**, one more — it is how a *VM* learns to
drive the cluster, and on an empty roster `--all` correctly refuses:

```bash
./provision.sh --all --no-deploy   # hand them the kubeconfig and image
```

What each one actually does:

* **`create`** enables the `k8s` beta feature in clever-tools, creates the
  cluster, polls until it is `ACTIVE`, writes `.secrets/kubeconfig.yaml`
  and `.secrets/k8s.env`, then creates the namespace and copies the
  fleet's secrets into it. It blocks for the whole control-plane build —
  expect minutes, not seconds, and do not take a timeout for a failure;
  re-run it and it resumes.
* **`image`** creates the GitLab project if needed (defaults to
  `<your-user>/vm-agent-images`; `--project <group>/<name>` overrides),
  builds `k8s/Dockerfile` with the repository root as context, pushes it,
  creates a `read_registry` deploy token for the cluster to pull with, and
  records `K8S_IMAGE` in `fleet.conf`.
* **`provision.sh --all --no-deploy`** publishes the kubeconfig, namespace
  and image to the shared config, so the VMs can spawn pods too. **This
  restarts every VM**, so check `fleet agents` for busy ones first — it
  refuses if any agent is working, and `--force` overrides. Skip it
  entirely on a pod-only fleet: there is nobody to publish to, `swarm`
  reads `.secrets/k8s.env` here, and `--all` would only tell you the
  roster is empty.

Only that last step needs the fleet to be quiet. The first two touch
nothing the VMs are using.

After that, `swarm` works on every VM and on this machine. Confirm with
one throwaway agent before handing the cluster to anything real:

```bash
swarm run hello "reply with just the word ok" --wait
```

### When it does not work

`./cluster.sh doctor` is the first move — it walks feature flag, cluster,
kubeconfig, reachability, namespace, both secrets and the image, and names
the first thing missing rather than the last thing that failed.

| Symptom | What it means |
|---|---|
| *no Configuration provider named …* | The shared config does not exist yet. Nothing was created. `./provision.sh --shared-only` — it needs no VM. |
| *your quota exceeded, contact support* | The offer is quota-limited. If the organisation's Kubernetes quota is zero or already spent, this needs a support request, not a flag — `clever k8s quota` shows it on clever-tools 4.9+. |
| `create` sits on `CREATING` for a long time | Normal. It polls for 30 minutes before giving up. |
| *registry.gitlab.com rejected the credential* | Checked before the build, so nothing is wasted. Usually an OAuth token from a browser `glab auth login`, which the registry does not accept — store a PAT with `write_registry` instead. |
| *docker buildx is unusable here* | Environmental, not fatal: docker falls back to the legacy builder and `cluster.sh` says so. Fix or remove `~/.docker/cli-plugins/docker-buildx` to silence docker's own DEPRECATED notice. |
| `ImagePullBackOff` on every pod | The pull secret is stale or the tag does not exist. Re-run `./cluster.sh image --yes`. |
| `swarm` says *no kubectl* | On a VM: the kubeconfig was never published — `./provision.sh --all --no-deploy`. On a laptop: `./cluster.sh kubeconfig`. |
| `--all` says *vms.txt is empty* | A pod-only fleet has no roster to apply to. `./provision.sh --shared-only` publishes the shared config with no VM; the cluster needs nothing else. |
| `swarm` says *no image* | `K8S_IMAGE` was never published. Same fix, after `./cluster.sh image`. |

### Sizing, and what this repository does not wrap

`clever k8s` is a beta feature whose options moved in clever-tools 4.9:
node groups, autoscaling, control-plane flavors and version pinning all
arrived there, while 4.5 creates a cluster with one default node group and
no knobs. `cluster.sh` only uses calls that exist in both, so it works on
either — but sizing is `clever k8s nodegroups` directly, not something
here:

```bash
clever k8s nodegroups list vm-agent-k8s
clever k8s nodegroups create vm-agent-k8s workers M:3
clever k8s quota                     # what the organisation is allowed
```

Per-pod resources are a different thing and do belong here:
`K8S_AGENT_CPU` / `K8S_AGENT_MEMORY` in `fleet.conf`, or `--cpu` /
`--memory` on a single `swarm run`.

`./cluster.sh storage` enables Ceph CSI, which is what `swarm start --pvc`
needs. Leave it off unless something actually wants a persistent
workspace — volumes bill separately, and pods are supposed to be
disposable.

## Docker and Testcontainers

A fleet VM cannot run a container: the `linux` runtime has an empty subuid
map and no cgroup delegation, so rootless podman never starts and there is
no daemon to talk to. `--dockerd` gets around that by giving a VM a
companion application on Clever's *docker* runtime with the instance's
socket mounted, reached over an ssh tunnel:

```bash
./provision.sh --dockerd owl        # owl gains owl-dockerd, and the wiring
./provision.sh --dockerd-only owl   # rebuild/repair the companion only
```

**It must be committed first.** The companion is deployed from git, so an
uncommitted `dockerd/Dockerfile` is simply not there; `provision.sh` checks
`HEAD` and says so before creating anything.

On the VM the tunnel opens at boot and every shell inherits `DOCKER_HOST`:

```bash
docker ps                 # the companion's daemon
./tunnel.sh status        # up? which ports are forwarded?
./tunnel.sh doctor        # start a real container and reach it, end to end
```

Published ports are forwarded to the VM's own loopback **at the same port
number**, so `getHost()`/`getMappedPort()` resolve to something locally
connectable. Verified against a real suite: 466 of `clever-kms`'s 470
Testcontainers-backed tests pass this way.

Four things do not work, all because the daemon is on another machine:

* **Bind mounts of local paths** (`-v $PWD:/x`, `withFileSystemBind`) —
  resolved over there, where the path does not exist. Copy into the
  container over the API instead.
* **`exposeHostPorts()`** — a container reaching a server on the VM. The
  tunnel is one-way.
* **Containers that advertise an address of their own.** You reach the
  published port, the service answers with its `172.17.0.x` bridge address,
  and the test *hangs* rather than failing — no error, ever. FoundationDB
  does this; `FDB_NETWORKING_MODE=host` makes it advertise loopback, which
  matches the forward. Postgres, Redis and friends are unaffected.
* **Bulk transfer through the API is slow.** `docker cp` of 24 MB takes
  ~2 minutes; `docker export` of an image filesystem is unusable. Image
  pulls are fine — they happen daemon-side.

Under heavy parallelism a Docker API read can stall for ever (~0.6% of
container cycles at `-j 6`), and Testcontainers sets no timeout there, so a
stall wedges the run instead of failing it. Keep test concurrency moderate
and set a per-test timeout.

One companion per VM: a shared daemon would let one agent reach and reap
another agent's containers. `--destroy <vm>` takes the companion with it.

## Reaching herdr itself

herdr's API is a unix socket on the VM with no network listener, and the
platform's ssh gateway refuses forwarding, so the fleet endpoint is the only
way to it. `fleet herdr` passes argv straight through, so any verb a herdr
release adds works without a redeploy:

```bash
fleet herdr <vm>                  # what is permitted, and the herdr version
fleet herdr agent-1 pane list
fleet herdr agent-1 api snapshot  # the whole live session state
```

Permitted: `agent`, `pane`, `tab`, `workspace`, `worktree`, `notification`,
`api`, `session`. Refused: `server`/`config`/`channel`/`integration` (they
change the box, not the session), anything `attach` (interactive - it would
never return), and `session stop`/`session delete` (they take every agent on
the VM with them). Those rules prevent accidents, not attackers: the fleet
token already grants code execution through `fleet prompt`.

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
* **No container runtime on the VM itself.** Rootless podman and docker are
  both dead here (empty subuid map, capless `newuidmap`, no cgroup
  delegation). `--dockerd` borrows one instead — see above.
* **The shared add-ons are found by name.** Changing `FLEET_NAME` or the
  `*_ADDON` values does not move storage, it abandons it: the old add-ons
  keep billing where nothing will look for them again. Purge before
  renaming, not after. `K8S_CLUSTER` behaves the same way.
* **`clever k8s` is beta and quota-limited.** It needs
  `clever features enable k8s` (`cluster.sh` does this), and an
  organisation with no Kubernetes quota cannot create one at all.
* **A pod cannot spawn pods.** The namespace's secret deliberately omits
  the kubeconfig, so delegation into the cluster starts from a VM or a
  laptop, never from another pod.

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

**None of those touch the Kubernetes cluster** — it is not an add-on
`provision.sh` knows about, and it is the most expensive thing that can be
left running. Tear it down separately, and say so when reporting that a
fleet is gone:

```bash
swarm ls                              # nothing still running on it?
./cluster.sh destroy --yes            # the control plane
./provision.sh --all --no-deploy --forget VM_AGENT_KUBECONFIG_B64
```

The GitLab project holding the agent image is left alone: it costs
nothing, and rebuilding it is the slow part of standing a cluster back up.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `fleet` says *no roster* | No fleet yet, or `.secrets/fleet.env` missing. Run `./provision.sh --all`. |
| A destroyed VM shows as unreachable | A stale `VM_AGENT_FLEET` exported in the shell. The file wins now, and says so. |
| VM reachable, agent never answers | It is blocked on a prompt. `fleet read` to see it, `fleet keys` to answer. |
| `fleet fetch` 404s | The agent has not written `~/out/<name>.md` yet, or ignored the instruction. Check with `fleet read`. |
| Deploy refuses | An agent is mid-task. `--force` overrides and kills its pane. |
| Adding a VM refuses because agents on *other* VMs are busy | The new name changes `VM_AGENT_FLEET`, and publishing it restarts every linked app. `--no-roster` creates and deploys the new VM without republishing, leaving the busy ones alone; re-run without it later to publish. |
| `--dockerd` deploy fails with *mandatory Dockerfile not found* | The work is uncommitted. Clever deploys the commit, not the working tree. |
| `docker ps` on a VM says the socket is missing | The tunnel is down. `./tunnel.sh status`, then `./tunnel.sh restart`; it supervises itself, so this usually means the companion app is down. |
| A container starts and the test hangs with no error | Either the tunnel (check `./tunnel.sh status` for the forward) or a service advertising its own bridge address — see Docker and Testcontainers. |
| Agent has no model access | No `CLAUDE_CODE_OAUTH_TOKEN` on the fleet. `./agent-tokens.sh claude`. |
| `swarm` says *kubectl is not installed* | This fleet has no cluster, or the VM booted before one was published. `./cluster.sh create`, then `./provision.sh --all --no-deploy`. |
| `swarm` says *no image* | `./cluster.sh image` has not run, or `K8S_IMAGE` was never published to the fleet. |
| A pod sits in `ImagePullBackOff` | The pull secret is stale or the tag does not exist. `./cluster.sh image` re-pushes and rewrites the secret. |
| `swarm fetch` finds nothing | The Job's TTL expired and Cellar has no copy — the pod had no `CELLAR_*` in its secret. `./cluster.sh secrets`. |
| An agent is listed but `prompt`/`keys` fail with *not an active named agent* | Something stamped a **reported agent label** on its pane (darwin does this when it takes one over). herdr treats that label as authoritative over its own live detection, and only *detected* agents accept input. `fleet read` still works. |
| An agent vanishes from `fleet agents` entirely | Its pane lost its `name`. **`herdr pane release-agent` clears the reported stamp and the name with it** — the session keeps running, but an unnamed, undetected pane is invisible to the fleet API, so a live agent looks dead. Re-add it with `herdr agent rename <pane-id> <name>` (positional target first). |
| A pane darwin spawned has no name at all | darwin calls `pane report-agent` (a label) but not `agent rename` (a name), so its panes are born nameless and unreachable from off the machine. |

Read `README.md` in the repository root for the reasoning behind any of
this, and `./provision.sh --help` / `fleet --help` for the full option
lists.
