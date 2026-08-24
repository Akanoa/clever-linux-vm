---
name: darwin
description: Run a feature or bugfix through mutation-verified TDD - an implementer agent must write tests first and then prove each test fails when the production code is mutated, an independent reviewer replays those mutations and attacks the gaps, and the orchestrator judges the evidence over multiple rounds. Use when the user asks for TDD that is actually enforced, for tests that are proven to catch regressions, for mutation testing of new work, or for cross-agent review of test quality. Provider- and language-agnostic; isolates each agent in its own worktree (herdr if installed, otherwise plain git worktrees).
---

# darwin - mutation-verified TDD

Tests that pass prove nothing. A test earns its place only when you can show the
code change that makes it fail. darwin runs a task through two isolated agents
and one mechanical verifier so that "the tests are good" stops being an opinion.

**You are the orchestrator.** You never write the feature and you never review
it — you set up isolation, spawn the two agents, replay their claims yourself,
judge, and decide whether to run another round or stop and call a human.

```
orchestrator ──spawn──> implementer  (own worktree: red -> green -> mutate -> report)
      │                     │
      │<────── report ──────┘
      ├── darwin verify  (replay every mutant patch, machine-checked)
      ├──spawn──> reviewer (own worktree: replay + adversarial mutants + test audit)
      │<────── review ──────┘
      └── judge: PASS / REVISE (next round) / ESCALATE (human)
```

The CLI is `python3 <skill-dir>/scripts/darwin.py`. Set `DARWIN=python3
/path/to/scripts/darwin.py` once and reuse it. Every command prints JSON.

## Before anything

```bash
$DARWIN doctor
```
Fix what it reports: a real test command, and a CLI on PATH for each agent
(or `"provider": "inline"`, see *Driving agents yourself*). `doctor` also tells
you whether isolation runs on herdr or plain git worktrees — both are supported
and you do not have to choose.

Ask the user before starting if any of these are unclear: what to build, which
model/provider each role should use, how many rounds are allowed. Defaults live
in `darwin.config.json` (see `darwin.config.example.json`).

## The loop

### 1. Open a run
```bash
$DARWIN init --task-file TASK.md            # or --task "..."
$DARWIN worktree add --role implementer     # branches from the base commit
```
`init` records the task, the resolved config and the base commit under
`.darwin/runs/<run-id>/`. That directory is the run's evidence and survives the
agents.

If the user is watching in herdr, give the run a face before you spawn anything:

```bash
$DARWIN ui        # a `darwin-run` workspace whose pane renders the live board
$DARWIN watch --once   # or the same board, once, right here
```

The orchestrator is wherever the skill was invoked, which is usually outside
herdr — so the roles would otherwise be the only visible thing. (When you *are*
running inside a herdr pane, darwin registers it as `darwin-orchestrator` and
reports your state as the loop moves.)

### 2. Implementer round
```bash
$DARWIN spawn --role implementer --round 1                 # first round
$DARWIN spawn --role implementer --round 2 --feedback-file feedback.md   # later rounds
```
The brief in `agents/implementer.md` is rendered with this run's paths and
handed to the agent: red commit before green commit, then a mutant per
behaviour, each captured as a patch and measured, then a report it must not
hand-edit. Feedback for round N+1 is the blocking list from round N's judgment,
written in your own words.

### 3. Verify the report yourself — do not skip this
```bash
$DARWIN verify --role implementer --round 1 --verifier orchestrator
```
This re-applies every mutant patch in the implementer's worktree, runs the suite
and diffs the outcome against what the report claimed. `fabricated_kills` means
the report said KILLED and the mutant in fact survives. Guards also fire on a
red baseline, deleted or skipped tests, loosened test configuration, mutants
that touch test files, and mutants that no longer apply.

You now know the truth of the mechanical claims before any reviewer speaks.

### 4. Reviewer round
```bash
$DARWIN worktree add --role reviewer      # branches from the implementer's branch
$DARWIN spawn --role reviewer --round 1
```
The reviewer replays the same mutants in its own worktree, grades their
*quality* (defect-shaped or vandalism? does it probe the new behaviour? is the
named killer specific?), writes its own adversarial mutants against whatever the
implementer avoided, audits the tests and the git history, and writes
`REVIEW.json` with `CONFIRM` or `DISPUTE`.

Use a **different provider or model** from the implementer when you can. Two
instances of the same model share the same blind spots.

With herdr, set `"spawn": "herdr-agent"` to run each role as a live, attachable
session in its own workspace instead of a headless command - useful when the
user wants to watch, or to step in. `references/providers.md` covers the modes.

### 5. Judge
```bash
$DARWIN judge --round 1
```
It merges report + your verification + the reviewer's verification + the review
into `judgment.json` and recommends `PASS`, `REVISE` or `ESCALATE`. The
recommendation is arithmetic; the verdict is yours. Read `blocking`, then record:

```bash
$DARWIN judge --round 1 --record REVISE --reason "M1 and M3 claimed KILLED, both survive"
```

- **PASS** - no blocking findings: every claim reproduced, no survivors without
  a justification you accept, the reviewer's in-task mutants all died, tests intact.
- **REVISE** - anything blocking. Write the feedback, then run round N+1 with
  the same implementer worktree (its history is the evidence trail).
- **ESCALATE** - stop and hand it to a human.

`judgment.json` carries a `trend` over all rounds so far - `converging`,
`partial`, `recurring`, `flat`, `converged` - naming which findings were closed,
which came back, and whether the reviewer's grading of the implementer's mutants
improved. Read it before you decide: a round that is still blocking but closed
everything from last round is the loop working, while the same finding reported
twice with nothing closed will not be fixed by asking a third time. With
`max_rounds: null` the trend is the only thing ending the loop, short of the
hard cap.

Judge the *evidence*, not the prose. A confident narrative with a fabricated
kill is worse than a blunt report that admits a survivor. Distinguish an honest
error (measured, then described wrongly) from a fabrication (never measured);
say which one you found and why.

Disagree with the reviewer when the evidence says so — an unsupported
accusation is a review defect, and you have the replay data to settle it.

### 6. Escalate when the loop stops converging
```bash
$DARWIN escalate --reason "..."
```
Call it — do not spend another round — when:
- claims were fabricated in two rounds (the default trigger), or
- `max_rounds` is reached and blocking findings remain, or
- your verification and the reviewer's disagree twice on the same patches: the
  suite is non-deterministic and no amount of reviewing fixes that, or
- the baseline suite cannot be made green, or
- the task turns out to be underspecified, or the two agents disagree about what
  correct behaviour even is.

Escalation is a success mode. It writes `ESCALATION.md` with the round history
and where to look, and pings herdr if it is running.

### 7. Land
```bash
$DARWIN land --strategy patch          # writes RESULT.patch, nothing is modified
$DARWIN land --strategy merge --yes    # merges the branch into the current checkout
$DARWIN clean --delete-branches        # remove worktrees; the evidence stays
```
**Ask the user before landing.** Report what was proven: mutants killed, what the
reviewer disputed, what remains uncovered.

## Driving agents yourself

If no agent CLI is installed, or you would rather run the roles as your own
subagents, set `"provider": "inline"` for that role and render the brief:

```bash
$DARWIN prompt --role implementer --round 1
```
Give that text to a subagent verbatim, with its working directory set to the
role's worktree. Everything else — capture, measure, verify, judge — is
unchanged, because it all runs through the CLI on files in the run directory.

## What makes this hold

- **Isolation**: each role gets its own worktree, so nobody can quietly fix what
  the other found. herdr workspaces when herdr is running, plain `git worktree`
  otherwise.
- **Replay, not trust**: mutations are stored as patches, so any party can re-run
  them and get the same answer. The report is a claim; `verify` is the fact.
- **Adversarial second pass**: the reviewer's own mutants target exactly what the
  implementer had an incentive to leave alone.
- **A bounded loop**: rounds are finite and anomalies reach a human instead of
  looping forever.

## Reference

- `references/protocol.md` - run layout, message bus, every command
- `references/mutation-catalog.md` - operators worth using, and what does not count
- `references/report-schema.md` - MUTATION-REPORT.json and REVIEW.json schemas
- `references/judging.md` - guard codes, discrepancy kinds, escalation triggers
- `references/providers.md` - configuring models, providers and custom CLIs
- `agents/implementer.md`, `agents/reviewer.md` - the briefs, as templates
