# Judging a round

`darwin judge --round N` merges four inputs — the report, your verification, the
reviewer's verification, and the review — into `rounds/rN/judgment.json` with a
recommendation. The recommendation is arithmetic. The verdict is the
orchestrator's, and it is recorded with `--record`.

## Guard codes

Guards come out of `verify`. `block` guards make the round `REVISE` on their own;
`warn` guards need a judgement call.

| code | severity | meaning |
|---|---|---|
| `G_BASELINE_NOT_GREEN` | block | the suite fails on the unmutated tree — nothing downstream means anything |
| `G_DIRTY_TREE` | block | uncommitted changes in the worktree at replay time; the report describes something other than what is committed |
| `G_HEAD_MISMATCH` | block | the report's `head_commit` is not the worktree's HEAD |
| `G_TEST_CMD_CHANGED` | block | the report ran a different suite than the one configured |
| `G_NO_TEST_CHANGES` | block | no test file added or modified — this is not TDD |
| `G_TEST_REMOVED` | block | tests deleted or renamed away since the base commit |
| `G_MUTANT_MISSING` | block | a mutant in the report has no patch file |
| `G_MUTANT_TOUCHES_TESTS` | block | a mutant edits tests instead of production code |
| `G_MUTANT_NOT_APPLICABLE` | block | a patch no longer applies — it was measured against different code |
| `G_REPORT_INCOMPLETE` | block | the report is the generated skeleton, unauthored: no `tests_added`, or the `TODO` narrative still in place |
| `G_REPORT_NO_RED_EVIDENCE` | warn | no `red_evidence` recorded, so nothing shows the tests preceded the code |
| `G_NAMED_KILLER_MISS` | block | the tests named as killers do not fail on that mutant; something else turned the suite red |
| `G_TOO_FEW_MUTANTS` | block | below `mutation.min_mutants` |
| `G_SURVIVORS` | block | a mutant survived with no equivalence justification |
| `G_KILL_RATE` | block | the kill rate is below `mutation.require_kill_rate` (default 1.0) |
| `G_TEST_CONFIG_TOUCHED` | warn | test or build configuration changed; check whether it shrinks the suite |
| `G_SKIP_MARKERS` | warn | added lines match skip / xfail / trivially-true assertion patterns |

## Discrepancy kinds

Per mutant, from comparing the claim with the replay:

| kind | meaning | how to read it |
|---|---|---|
| `fabricated_kill` | claimed KILLED, actually SURVIVED | the serious one: either it was never run, or the outcome was rewritten |
| `understated_kill` | claimed SURVIVED, actually KILLED | usually a stale measurement taken before the last test was added |
| `named_killer_does_not_kill` | the suite goes red, but not the test that was named | the mutant is caught by something else; the specific proof is missing |
| `patch_does_not_apply` | the patch no longer applies to HEAD | measured against code that then changed |
| `missing_patch` | the report names a mutant with no patch | nothing to replay, nothing proven |

One `understated_kill` in an otherwise honest report is an error. A
`fabricated_kill` is a different category, and repeats of it are what escalate a
run. Say which one you found, and why you read it that way.

## Verdicts

**PASS** — every claim reproduced, no blocking guards, no survivor without a
justification you accept, the reviewer's adversarial mutants all died, tests
intact, and the reviewer's `CONFIRM` matches your own reading of the evidence.

**REVISE** — anything blocking. Write feedback that names the mutant ids, the
guard codes and what specifically must change, then run round N+1 in the same
implementer worktree. The history is part of the evidence; do not start clean.

**ESCALATE** — stop the loop and write `ESCALATION.md`.

## Reading the trend, not just the round

`judge` also looks back over every round of the run and puts a shape on the
sequence, in `judgment.json` under `trend`. One round tells you whether the work
is good; the sequence tells you whether the loop is worth continuing.

| shape | what it means | what to do |
|---|---|---|
| `converged` | nothing in-task survives, no guards, no fabrications | **PASS**. Any leftover `beyond-task` survivors are feature requests to hand back, not defects |
| `converging` | the previous round's findings are closed and the reviewer has moved to new ground | **REVISE**, keep going - this is the loop working |
| `partial` | some findings closed, some still open | **REVISE**, and say in the feedback which ones were ignored |
| `recurring` | the same findings came back with nothing closed | **ESCALATE**. The implementer is not acting on the review, and another round will produce the same paragraph |
| `flat` | nothing closed, nothing new, no more mutants | **ESCALATE**. The round changed nothing |

`trend.closed`, `trend.repeated` and `trend.new` name the specific mutants, and
`quality_delta` tracks the reviewer's own grading of the implementer's mutants
between rounds. Rising quality with new-frontier findings is convergence even
when the blocking count does not fall - the work is getting better and the
reviewer is having to dig harder to find anything.

`max_rounds: null` hands the stopping decision entirely to these shapes, bounded
by `hard_round_cap` (default 8) so a pathological run still terminates. A fixed
`max_rounds` remains available and simply adds one more escalation trigger.

## Escalation triggers

Defaults, and all of them are judgement calls you can make earlier:

1. **Fabrication in two rounds** (`escalate_after_fabrications`, default 2). An
   agent that rewrites outcomes twice will not stop on the third ask.
2. **`max_rounds` reached with blocking findings** (default 3).
3. **Two rounds where verifications disagree.** Same commit, same patches,
   different results means the suite is non-deterministic. No amount of reviewing
   fixes a flaky suite, and every claim built on it is unfalsifiable.
4. **The baseline cannot be made green.** The environment, not the agent, is the
   problem.
5. **The task is underspecified.** If implementer and reviewer disagree about
   what correct behaviour *is*, that is a question for the person who asked, not
   another round.
6. **The reviewer has moved past the task.** An adversarial reviewer can always
   find another survivor - parse stricter, bound tighter, invent a rule the task
   never stated. Survivors marked `beyond-task` do not block; if the remaining
   findings are all of that kind, the round is a PASS with feature requests
   attached, not a failure. Watch for this from round two on: rising mutant
   quality plus new-frontier survivors is convergence, not deadlock, and the
   right response may be one more round or a wider `max_rounds`, not a stop.
7. **The mutation set keeps missing the point.** Rising kill rates on mutants
   that avoid the behaviour under test means the loop is being satisfied instead
   of the requirement.

Escalating is a success mode of this workflow. The failure mode is burning
rounds on evidence that was never going to converge.

## Writing feedback for the next round

Point at artefacts, not adjectives. Useful feedback looks like:

```
Round 1 = REVISE.

- M1 and M3 claimed KILLED; both survive on replay (verify.orchestrator.json).
  Re-measure with `darwin mutant run`; do not hand-write claimed values.
- M1 is equivalent, not killed: s[:0] is already "". Either delete the redundant
  guard or justify it - and if you keep it, expect the reviewer to attack that.
- The reviewer's RM1 (truncation off-by-one) survives. Add the test that kills it.
- Uncovered behaviour from the diff: the leading-dash trim after truncation.
```

Each line names an id or a file, and each says what would settle it.
