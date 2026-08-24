# darwin protocol

Everything darwin does lands in files under `.darwin/` in the repository being
worked on. Nothing is held in an agent's head, so any party — a later round, a
different model, a human — can reconstruct what happened.

`.darwin/` is added to `.git/info/exclude` on `init`, which keeps it out of git
without touching the user's `.gitignore`. Linked worktrees share that exclude
file, so agent worktrees stay clean too.

## Run layout

```
.darwin/
├── current                       # run id of the most recent run
├── worktrees/<run-id>/
│   ├── implementer/              # isolated checkout, branch darwin/<run-id>/implementer
│   └── reviewer/                 # isolated checkout, branched off the implementer
└── runs/<run-id>/
    ├── run.json                  # config, base commit, roles, round, history, status
    ├── TASK.md                   # the brief the run was opened with
    ├── ESCALATION.md             # written only when a human is called in
    ├── RESULT.patch              # written by `land --strategy patch`
    ├── bus/
    │   ├── messages.jsonl        # append-only, sequence-numbered
    │   └── inbox/<role>/NNNN-<type>.json
    └── rounds/rN/
        ├── judgment.json
        ├── implementer/
        │   ├── PROMPT.md         # the exact brief this agent was given
        │   ├── agent.log         # the agent's stdout/stderr
        │   ├── spawn.json        # provider, model, argv, exit code, duration
        │   ├── mutants/M1.patch  # the mutation, replayable by anyone
        │   ├── mutants/M1.json   # operator, intent, expected killers
        │   ├── mutants/M1.result.json
        │   ├── MUTATION-REPORT.json
        │   ├── verify.orchestrator.json
        │   └── verify.reviewer.json      (when the reviewer writes it here)
        └── reviewer/
            ├── PROMPT.md, agent.log, spawn.json
            ├── mutants/RM1.*     # the reviewer's adversarial mutants
            ├── verify.reviewer.json
            └── REVIEW.json
```

Branch names are `<branch_prefix>/<run-id>/<role>`, prefix `darwin` by default.
The implementer branches from the run's base commit; the reviewer branches from
the implementer's branch, so both see identical code and mutant patches apply in
either worktree.

## Isolation

`isolation` is `auto` by default: herdr if `herdr status` answers, plain
`git worktree` otherwise. With herdr, `worktree create` also opens a workspace,
and the workspace id and root pane id are stored in `run.json`; `clean` closes
them again. A failing herdr call always falls back to git rather than aborting
the run — isolation is the requirement, herdr is the convenience.

## Message bus

Payloads are always files; the bus carries pointers to them. `bus` is `auto`:
with herdr it additionally raises a desktop notification per message (and
prompts a registered interactive agent, if `run.json` names one under
`roles.<role>.herdr_agent`); otherwise it is pure files. Polling
`messages.jsonl` works from any language, any harness, with no daemon.

```bash
$DARWIN msg send --from implementer --to orchestrator --type report \
        --round 1 --body-file .../MUTATION-REPORT.json
$DARWIN msg wait --to orchestrator --type report --timeout 3600   # exits 1 on timeout
$DARWIN msg list --to orchestrator --since 4
```

Message: `{seq, ts, from, to, type, round, body}`. Types in use: `assignment`,
`report`, `review`, `agent_exit`, `escalation`. `from`/`to` are free-form;
`human` is a valid recipient and is what `escalate` writes to.

## Command reference

| command | what it does |
|---|---|
| `doctor` | git, herdr, provider CLIs, detected test command, config source |
| `init --task/--task-file` | open a run; records config + base commit |
| `status` | run state, roles, history, last judgment |
| `worktree add\|remove\|list --role R` | isolated checkout for a role |
| `prompt --role R --round N` | render the role brief (drive the agent yourself) |
| `spawn --role R --round N` | render the brief and launch the role's agent CLI |
| `msg send\|wait\|list` | the file bus |
| `mutant capture --role R --id M1 ...` | snapshot the current edit as a patch, then revert |
| `mutant run --role R [--id M1]` | apply, run the suite, revert, record |
| `report build --role R [--baseline]` | assemble the measured report skeleton |
| `verify --role R [--report P] --verifier NAME` | replay every mutant, diff against the claims |
| `judge --round N [--record VERDICT --reason ...]` | merge the evidence into a verdict |
| `watch [--once] [--follow]` | live status board: roles, herdr state, per-round evidence, bus tail |
| `ui` | open a `darwin-run` herdr workspace whose pane renders that board |
| `escalate --reason ...` | write ESCALATION.md, notify, mark the run escalated |
| `land --strategy patch\|merge` | export or merge the accepted branch |
| `clean [--delete-branches] [--purge]` | remove worktrees; `--purge` also deletes the evidence |

`--run <id>` targets a specific run; the default is `.darwin/current`.

## The mutation cycle, mechanically

`mutant capture` runs `git diff` in the role's worktree, refuses the capture if
it touches a test file, stores the patch plus its metadata, and reverts the
working tree. `mutant run` applies the patch, runs the suite, records the exit
code and an output digest, and reverts. `verify` does the same replay from a
report and compares each outcome with what was claimed.

Because a mutant is a patch, "the test caught it" is reproducible: same commit,
same patch, same command, same answer. A claim that cannot be reproduced is a
fabrication, and that distinction is what the whole workflow rests on.

Build caches are the quiet failure mode here: a mutate-test-revert cycle can
finish inside one clock second, and anything keyed on whole-second mtimes (CPython
`__pycache__`, `make`, incremental compilers) may then serve an artefact built
from the mutant. darwin pushes every file a patch touches one second forward after
each apply and revert, bumps them again before the baseline run, and sets
`PYTHONDONTWRITEBYTECODE=1` by default via `test.env`. If your toolchain caches on
something else, add its opt-out to `test.env`.

Non-zero exit means KILLED, zero means SURVIVED, and a suite timeout is recorded
as TIMEOUT (killed, but flagged — an infinite loop is not the same evidence as a
failing assertion). When `test.single_command` is configured, the tests the
report names as killers are also run individually, so "some test somewhere went
red" cannot pass for proof.

## Self-test

```bash
scripts/selftest.sh [workdir]
```

Builds a throwaway repository, runs an honest round to `PASS` and a dishonest one
to `REVISE`, and asserts that isolation, capture/revert, the test-mutation
refusal, deterministic replay, the guards, escalation and cleanup all behave. Run
it after changing `darwin.py`.
