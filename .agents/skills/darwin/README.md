# skill-darwin

An agent skill that makes TDD *verifiable*. Tests that pass prove nothing; a test
earns its place only when someone can show the code change that makes it fail.

darwin runs a task through an **implementer** agent that must write tests before
code and then mutate its own production code to prove each test can fail, a
**reviewer** agent that replays those mutations independently and attacks the
gaps, and an **orchestrator** that verifies both mechanically and decides whether
the work is done, needs another round, or needs a human.

Provider-agnostic (Claude, Codex, Gemini, Cursor, opencode, amp, or any CLI you
configure), language-agnostic (anything with a test command), and dependency-free
beyond `git` and Python 3.8+.

```
orchestrator ──spawn──> implementer  (own worktree: red → green → mutate → report)
      │                     │
      │<────── report ──────┘
      ├── darwin verify   replays every mutant patch; the report is a claim, this is the fact
      ├──spawn──> reviewer (own worktree: replay + adversarial mutants + test audit)
      │<────── review ──────┘
      └── judge: PASS / REVISE (another round) / ESCALATE (human review)
```

**[WORKFLOW.md](WORKFLOW.md) is a real run on the record** — two rounds, both
agents' output, every number reproduced from the artefacts, ending in a PASS the
orchestrator decided on. Read that first if you want to know what this actually
does.

## Why mutation, and not coverage

Coverage says a line ran. It does not say anyone would notice if that line were
wrong. A mutant answers the question that matters: *if someone shipped this bug,
would the suite catch it?* A test that survives its mutant is decoration, and a
suite of decorations will not catch tomorrow's regression either.

Because a mutation is stored as a patch, the claim "my test catches this" is
reproducible by anyone, at any later point. That is what turns a report into
evidence, and what lets an orchestrator tell an honest mistake from a fabricated
result instead of taking an agent's word for it.

## How it works

### Three roles, and what each one may not do

**The implementer** writes the code. It works alone in its own git worktree and
never sees the reviewer. Its protocol is fixed: a failing test committed as
`red:` before the code that satisfies it, committed as `green:`, per behaviour —
then, for each behaviour, a *mutant*: a small edit to the production code that
simulates a defect a person could plausibly ship, which its test must catch.

**The reviewer** never writes code, never commits, never pushes. It gets its own
worktree at the implementer's head, replays every mutation itself, grades whether
each one proves anything, and then attacks whatever the implementer left alone
with mutants of its own.

**The orchestrator** writes nothing and reviews nothing. It sets up isolation,
dispatches the roles, runs the mechanical verification itself, and decides:
accept, another round, or stop and call a human.

The division of labour is the point. The machine settles what is *reproducible*;
the reviewer judges what is *meaningful*; the orchestrator weighs the two. None of
them is asked to grade its own work.

### A round, step by step

```bash
darwin init --task-file TASK.md          # records the task, config and base commit
darwin worktree add --role implementer   # isolated checkout on its own branch
darwin spawn --role implementer --round 1
```

`spawn` renders `agents/implementer.md` with this run's real paths, writes it to
`.darwin/PROMPT.md` inside the worktree, and launches the configured agent CLI
with a one-line bootstrap: *read that file and follow it*. The brief is a file,
not an argument, which is why any provider works and why length is never a
problem.

Inside the worktree, the agent drives darwin itself:

```bash
# edit the production file so the defect exists, then:
darwin mutant capture --role implementer --id M1 --operator boundary \
  --intent "upper bound made inclusive" \
  --expected-killers "tests.test_duration.TestParseDuration.test_hours"
darwin mutant run --role implementer          # apply, run the suite, revert, record
darwin report build --role implementer --baseline
```

`capture` refuses outright if the edit touches a test file — mutants change
production code, nothing else — stores it as a **patch**, and reverts the tree.
`run` measures each patch. `report build` assembles the report from those
measurements, and the agent may only annotate the prose fields around them.

Then the orchestrator checks the claims rather than reading them:

```bash
darwin verify --role implementer --round 1 --verifier orchestrator
```

This re-applies every patch, re-runs the suite, and diffs what happened against
what was claimed:

```json
{"total": 5, "killed": 5, "kill_rate": 1.0,
 "claim_mismatches": [], "fabricated_kills": [], "blocking_guards": []}
```

A `fabricated_kill` is a mutant reported KILLED that survives on replay. There is
no arguing with it, and no way to talk past it.

```bash
darwin worktree add --role reviewer      # branches from the implementer's branch
darwin spawn --role reviewer --round 1
darwin judge --round 1
```

The reviewer replays the same patches in its own worktree — two independent
replays that must agree, or the suite is non-deterministic and every claim built
on it is unfalsifiable. Then it does the part no script can, and writes
`REVIEW.json` with `CONFIRM` or `DISPUTE`.

### What is checked mechanically

Not by an agent reading prose. By replaying patches and diffing outcomes:

- every mutant re-applied and re-run, its result compared with the claim
- the test *named* as the killer run on its own, and required to be the one that
  fails — "the suite went red somewhere" is not proof
- the baseline suite green on the unmutated tree
- tests added, and never deleted, renamed away, skipped, or made trivially true
- test and build configuration unchanged
- mutants that touch test files, or no longer apply, rejected
- the report's `head_commit` matching the worktree, and the worktree clean
- the report actually authored, not the generated skeleton

Each failure is a guard code (`G_SURVIVORS`, `G_NAMED_KILLER_MISS`,
`G_TEST_REMOVED`, …) with a severity. Blocking guards end the round on their own.

### What the reviewer judges instead

Everything the guards cannot reach — starting with whether the mutants were worth
writing. From a real run of the demo, on a task that added a unit-validation
guard and a numeric bound:

> all four of my adversarial mutants survived, because **every implementer mutant
> is the inverse of a diff hunk**

That is the failure mode of mutation testing done unsupervised: mutating only what
you just wrote proves the line is *reached*, not that the *rule* is pinned. The
implementer's report was honest — 5/5 killed, both replays agreeing, zero
fabrications, red-before-green confirmed commit by commit — and it was still not
good enough, because `float()` instead of `int()`, `<= 0` instead of `< 0`, and a
validator list drifting out of step with its lookup table all sailed through the
suite untouched.

Nothing mechanical catches that. A second agent, with its own worktree and an
incentive to attack, does.

The same run makes the opposite point in round two. The implementer adopted all
four of those mutants, went from 5 to 8, upgraded every `assertRaises` to
`assertRaisesRegex`, took its test file from 2 to 11 tests — and the reviewer
graded all eight mutants `strong`, up from two. It also found four *new*
survivors on a deeper frontier (`5M` accepted by case-folding, `int(x, 0)` making
`0x10s` mean 16). That is what convergence looks like, and it is also the reason a
reviewer needs a leash: you can always mutate deeper. Adversarial mutants are
marked `in-task` or `beyond-task`, and only the first kind blocks a round — the
second is a feature request wearing a coverage gap's clothes.

### Rounds

A `DISPUTE`, a fabricated claim, a surviving mutant, or any blocking guard makes
the round `REVISE`. `darwin feedback --round N` drafts the brief-back from that
round's own evidence — each surviving reviewer mutant with the `git apply` line
that reproduces it, the mutants graded weak and why, the coverage gaps, anything
reported as dishonesty — and the next round runs in the *same* worktree, because
the history is part of the evidence.

How long the loop runs is a judgement, not a counter. `judge` compares every
round against the ones before it and puts a shape on the sequence — `converging`
when the previous round's findings are closed and the reviewer has moved to new
ground, `partial` when some were ignored, `recurring` when the same findings come
back untouched, `flat` when a round changed nothing, `converged` when nothing
in-task survives. Set `max_rounds: null` and those shapes decide, bounded by a
hard cap so a pathological run still ends.

`darwin escalate` stops the loop and writes `ESCALATION.md` when findings recur
with nothing closed, when a run stalls for two rounds, when claims were fabricated
twice, when two rounds' verifications disagree (a flaky suite cannot be reviewed
into reliability), or when the two agents turn out to disagree about what correct
behaviour even is. **Escalation is a success mode.** The failure mode is
burning rounds on evidence that was never going to converge.

### Why the isolation matters

Each role gets its own worktree on its own branch, so the implementer cannot
quietly patch what the reviewer found and the reviewer cannot "help". It also
means the run survives its own orchestrator: state lives in files under
`.darwin/runs/<run-id>/`, so a killed orchestrator is resumed by re-running the
step it died in. That is not theoretical — it happened twice while building this,
and both agents carried on and finished in their panes.

## Install

```bash
git clone https://github.com/<you>/skill-darwin ~/.claude/skills/darwin
```

Or from an existing clone, for one project:

```bash
mkdir -p .claude/skills && ln -s /path/to/skill-darwin .claude/skills/darwin
```

Then, in Claude Code, `/darwin` — or just ask for a feature "with enforced TDD".
The skill is a plain directory of Markdown plus one Python script, so any harness
that can read `SKILL.md` and run a command can drive it.

## Quickstart

```bash
DARWIN="python3 ~/.claude/skills/darwin/scripts/darwin.py"

$DARWIN doctor                                   # environment check first
$DARWIN init --task "Reject empty slugs with a ValueError"
$DARWIN worktree add --role implementer
$DARWIN spawn  --role implementer --round 1
$DARWIN verify --role implementer --round 1 --verifier orchestrator
$DARWIN worktree add --role reviewer
$DARWIN spawn  --role reviewer --round 1
$DARWIN judge  --round 1
```

`judge` prints the blocking findings and a recommendation; record the verdict
with `--record PASS|REVISE|ESCALATE --reason "..."`. On `REVISE`, run round 2
with `--feedback-file`. When it passes, `land --strategy patch` writes
`RESULT.patch` and `clean` removes the worktrees. The evidence stays behind in
`.darwin/runs/<run-id>/`.

## Isolation

Each role works in its own git worktree on its own branch, so the implementer
cannot quietly patch what the reviewer found, and the reviewer cannot "help".

If [herdr](https://herdr.dev/) is running, worktrees become herdr workspaces and
each agent runs in a persistent pane: it survives a closed laptop, you can watch
it live, and role state (`working` / `idle` / `blocked`) shows up in the herdr UI.
Without herdr it is plain `git worktree` and a subprocess. Messages are files
either way — an append-only `messages.jsonl` plus per-role inboxes — with herdr
adding notifications on top. Nothing requires a daemon, and a herdr failure falls
back rather than losing a round.

## Configuration

Copy `darwin.config.example.json` to `darwin.config.json` in your repository.
The essentials:

```json
{
  "test": { "command": "npm test --silent",
            "single_command": "npm test --silent -- -t {selector}" },
  "max_rounds": 3,
  "mutation": { "min_mutants": 5 },
  "agents": {
    "implementer": { "provider": "claude", "model": "claude-opus-5" },
    "reviewer":    { "provider": "codex",  "model": "gpt-5" }
  }
}
```

`test.env` injects environment variables into every test run — it defaults to
`PYTHONDONTWRITEBYTECODE=1`, since a stale bytecode cache is the classic way for a
mutate-and-revert cycle to produce a result that is not reproducible.

`single_command` is worth setting: it lets the verifier run the specific test the
report names as the killer, so "the suite went red somewhere" cannot pass for
proof. Environment variables (`DARWIN_TEST_CMD`, `DARWIN_IMPL_MODEL`, …) and CLI
flags override the file; `doctor` shows what resolved.

Give the two roles different models. A reviewer that shares the implementer's
blind spots agrees for the wrong reasons.

## Layout

```
SKILL.md                   the orchestrator's playbook
agents/implementer.md      the brief: red → green → mutate → report
agents/reviewer.md         the brief: replay → grade → attack → report
scripts/darwin.py          the whole CLI (stdlib only)
references/protocol.md     run layout, message bus, command reference
references/mutation-catalog.md   operators worth using, and what does not count
references/report-schema.md      MUTATION-REPORT.json, verify.json, REVIEW.json
references/judging.md      guard codes, discrepancy kinds, escalation triggers
references/providers.md    models, providers, custom CLIs, inline mode
```

## Checking it works

```bash
scripts/selftest.sh          # builds a throwaway repo and runs the whole loop
```

17 assertions covering isolation, capture/revert, the refusal to mutate tests,
deterministic replay, the guards, both verdict paths, escalation and cleanup.

## Requirements

`git` (worktrees), Python 3.8+, a test command that exits non-zero on failure,
and at least one agent CLI on `PATH` — or `"provider": "inline"` to drive the
roles from your own harness.

## License

See [LICENSE](LICENSE).
