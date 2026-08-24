# A run, on the record

This is not an illustration. It is one real `scripts/demo.sh` run, reproduced
from the artefacts it left behind — every number, quote and commit below comes
out of `.darwin/runs/<run-id>/`. It took **14 minutes 55 seconds of agent time**
across two rounds and ended in a PASS the orchestrator decided on, not one a
counter allowed.

| | |
|---|---|
| task | extend a duration parser: hours, and four rejection cases |
| repo | 2 source files, 2 tests, Python + `unittest`, no dependencies |
| implementer | Claude Sonnet, live in a herdr pane |
| reviewer | Claude Opus, live in a second herdr pane |
| `max_rounds` | `null` — the orchestrator decides when to stop |
| outcome | **PASS** at round 2, trend `converged`, 2 feature requests handed back |

## The task

```
Extend `parse_duration` in src/duration.py:

- support hours, e.g. "2h" -> 7200
- raise ValueError for an unknown unit, e.g. "5x"
- raise ValueError for an empty string
- raise ValueError for a missing number, e.g. "s"
- raise ValueError for a negative duration, e.g. "-5m"

Keep the return value a whole number of seconds. Do not add dependencies.
```

The starting code handled seconds and minutes and validated nothing.

---

## Round 1

### Dispatch

The orchestrator opens the run, creates an isolated worktree, and hands the role
its brief. The bus records it as message `#1: orchestrator -> implementer`.

```bash
darwin init --task-file TASK.md
darwin ui                                   # the run's own herdr workspace
darwin worktree add --role implementer
darwin spawn --role implementer --round 1
```

### The implementer works — 4 min 35 s

Its git history is the evidence that the tests came first. Read it bottom-up:

```
3895d82 green: negative duration raises ValueError; explicit number validation
9e039fa red:   negative duration raises ValueError (missing number already covered incidentally)
84eba2a green: empty string raises ValueError
8839ece red:   empty string raises ValueError
47cbd36 green: unknown unit raises ValueError
e4b5b35 red:   unknown unit raises ValueError
25f636a green: hours support
9269693 red:   hours support
```

Then five mutants, each captured as a replayable patch and measured:

| id | operator | the defect it simulates |
|---|---|---|
| M1 | default-value | hour constant typo'd, `3600` → `360` |
| M2 | guard-removal | unit validation skipped — `5x` gets through |
| M3 | guard-removal | empty-string validation skipped |
| M4 | guard-removal | negative validation skipped |
| M5 | error-handling | invalid number swallowed, defaults to zero |

Report: 5 mutants, 5 claimed killed.

### The orchestrator checks the claims itself

```bash
darwin verify --role implementer --round 1 --verifier orchestrator
```
```json
{"total": 5, "killed": 5, "kill_rate": 1.0,
 "claim_mismatches": [], "named_killer_misses": [],
 "fabricated_kills": [], "blocking_guards": []}
```

Every patch re-applied, every suite re-run, every claim reproduced. The report is
honest. That settles the mechanical question and nothing else.

### The reviewer — 3 min 23 s, its own worktree

It replays the same five patches independently (same result), then grades them.
All five come back `strong` individually — and it disputes the round anyway:

> All five implementer mutants are the same shape (delete/neuter one guard). They
> prove each guard exists; **none probes what any guard's boundary is**.

Then it attacks what that shape leaves alone:

| id | scope | result | the defect |
|---|---|---|---|
| RM1 | in-task | **SURVIVED** | `if value < 0` → `<= 0`, so `0s` is rejected |
| RM2 | in-task | **SURVIVED** | `float()` instead of `int()`, so `2h` returns `7200.0` |
| RM3 | beyond-task | SURVIVED | a unitless `90` silently defaults to seconds |
| RM4 | in-task | KILLED | empty string returned as zero |

with the coverage gaps spelled out against line numbers:

> `src/duration.py:18` — the boundary of `if value < 0` is untested; no test
> exercises a zero duration, so `<=` vs `<` is invisible
>
> `src/duration.py:15,20` — the whole-number-of-seconds requirement is untested;
> every assertion uses `assertEqual` against an int, which cannot distinguish
> `7200` from `7200.0`

**Verdict: DISPUTE.** Zero dishonesty findings — the implementer was straight
with them; its tests were simply not as good as its report was honest.

### Judgment and brief-back

```
recommendation: REVISE   trend: first-round
blocking: reviewer DISPUTES the report
blocking: reviewer's adversarial mutants survived: RM1, RM2
```

`darwin feedback --round 1` turns that into the next brief automatically — each
survivor with the `git apply` line that reproduces it, why it matters, the
coverage gaps, and the instruction to adopt the mutants rather than merely
patch around them.

---

## Round 2

Same worktree, same agent session, brief-back attached. The implementer adopts
**RM1 → M6, RM2 → M7, RM3 → M8** — including the one marked beyond-task — adds
four tests, and tightens every `assertRaises` to `assertRaisesRegex`:

```
12eb06c test: pin zero-boundary, whole-number return type, fractional rejection
        and unitless rejection; tighten error tests to assertRaisesRegex
```

There is no `red:` commit this round, and the report says so: the four new tests
passed on first write because the production code was already correct. A pure
regression-coverage round has no red phase, and the implementer disclosed that
per test instead of staging a fake failure.

The reviewer verified the disclosure rather than accepting it:

> `src/duration.py` is unchanged between `3895d82` and `12eb06c`, which
> corroborates the report's claim that the four new tests passed on first write

and verified the adoptions were genuine, not look-alikes:

> the three mutants adopted as M6/M7/M8 are **byte-for-byte identical to my
> round-1 RM1/RM2/RM3 — I diffed the patch hunks** — so the round-1 survivors are
> provably closed rather than replaced by look-alikes

Its five new attacks: three killed, two survived — and it marked both survivors
`beyond-task` itself (`2H` via case-folding; a negative check on the raw text
prefix). The task never mentioned case-insensitivity.

**Verdict: CONFIRM.**

## The decision

```
recommendation: PASS      trend: converged
closed: [RM1, RM2]   repeated: []   new: []
remaining survivors are all beyond the task: [RM6, RM9]

round  mutants  kill_rate  strong_ratio  in-task survivors  beyond-task
  1       5        1.0         1.0              2                1
  2       8        1.0         1.0              0                2
```

Two things ended this loop, and neither is a counter:

- **scope** — two mutants survived round 2. Under a rule where any survivor
  blocks, the run would have continued until it hit a cap and then escalated
  finished work. Both were out of the task's scope, so they were recorded as
  feature requests in the judgment notes and did not block.
- **trend** — `closed: [RM1, RM2]`, `repeated: []`. Every finding from round 1
  was closed and none came back. That is `converged`, and the orchestrator
  stopped.

Had the same findings returned untouched, the shape would have been `recurring`
and the run would have escalated to a human instead of asking a third time.

## What landed

```
 src/duration.py        | 17 ++++++++++++++---
 tests/test_duration.py | 33 +++++++++++++++++++++++++++++++++
 2 files changed, 47 insertions(+), 3 deletions(-)
```

Tests went from 2 to 11. Every one of them is backed by a patch that makes it
fail — replayable by anyone, from the artefacts, at any later date.

```python
UNITS = {"s": 1, "m": 60, "h": 3600}


def parse_duration(text):
    """Parse a duration like '90s', '5m' or '2h' into a whole number of seconds."""
    if not text:
        raise ValueError("empty duration string")
    unit = text[-1]
    if unit not in UNITS:
        raise ValueError(f"unknown unit: {unit!r}")
    number = text[:-1]
    try:
        value = int(number)
    except ValueError:
        raise ValueError(f"missing or invalid number: {number!r}") from None
    if value < 0:
        raise ValueError(f"negative duration: {text!r}")
    return value * UNITS[unit]
```

## What the record shows

**The machine settled what is reproducible.** Thirteen implementer mutants, each
replayed by two parties in separate worktrees, always with the same answer — plus
nine more written by the reviewer, twenty-two patches in all, every one still on
disk and still replayable. Every claim in both reports reproduced; a fabricated
one would have been named, not argued about.

**The reviewer caught what no guard can.** All five round-1 mutants were
individually `strong` and every claim about them was true — and the set was still
inadequate, because they were all the same shape. That is a judgement about
whether the evidence *means* anything, and it is the reason the second agent
exists. It also diffed patch hunks to confirm adoptions were real and checked a
file's history to corroborate an absence of red commits: verification behaviour
nobody scripted.

**The trend ended the loop.** Not a round limit — a reading of what the sequence
of rounds was doing. Same task, same models, an earlier run with `max_rounds: 2`
and no scope rule escalated work that was, in fact, finished.

**Honesty was never the failure mode here.** Zero dishonesty findings across both
rounds; the implementer volunteered its weakest evidence twice. The workflow is
built to detect fabrication, but what it actually bought on this run was a
better test suite.

## Reproducing it

```bash
scripts/demo.sh ~/darwin-demo        # real agents, real tokens, watchable in herdr
scripts/selftest.sh                  # the mechanical half, 18 checks, no agent CLI
```

Every artefact quoted here lives under `.darwin/runs/<run-id>/` — reports,
mutant patches, both verifications, both reviews, the judgments and their trends,
and the message bus. `darwin watch` renders it live; `references/protocol.md`
maps the directory.
