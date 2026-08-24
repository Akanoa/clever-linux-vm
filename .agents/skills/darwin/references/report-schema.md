# Report schemas

Two documents carry a round: `MUTATION-REPORT.json` (the implementer's claims)
and `REVIEW.json` (the reviewer's findings). A third, `verify.<name>.json`, is
produced by the tool, never by an agent, and is what the other two are checked
against.

## MUTATION-REPORT.json

`darwin report build --role implementer --round N --baseline` writes this file
with every measured field already filled from `mutants/*.result.json`. The agent
then annotates the prose fields and nothing else.

```jsonc
{
  "run_id": "20260820-223016-add-a-max-len-guard",
  "round": 1,
  "role": "implementer",
  "generated_at": "2026-08-20T20:30:50+00:00",
  "branch": "darwin/<run-id>/implementer",
  "head_commit": "7f70c5f...",          // verified against the worktree at replay time
  "base_commit": "c5ee3cd...",
  "test": {
    "command": "python3 -m unittest discover -q -s . -p \"test_*.py\"",
    "single_command": "python3 -m unittest -q {selector}",
    "baseline": { "exit_code": 0, "duration_s": 0.03, "timed_out": false,
                  "output_tail": "...", "output_digest": "sha256:3afcae53..." }
  },
  "changed_files": [ { "status": "M", "path": "src/slug.py" } ],

  // --- filled in by the agent -------------------------------------------
  "tests_added": [
    { "file": "tests/test_slug.py", "name": "test_zero_max_len_returns_empty",
      "covers": "max_len=0 returns an empty slug" }
  ],
  "red_evidence": [
    { "behaviour": "max_len=0 returns an empty slug", "commit": "9ab12cd",
      "test": "test_zero_max_len_returns_empty", "exit_code": 1,
      "excerpt": "AssertionError: 'hello' != ''" }
  ],
  "narrative": "What was built, what each mutant probes, what the survivors taught me.",
  // ----------------------------------------------------------------------

  "mutants": [
    {
      "id": "M1",
      "patch": "mutants/M1.patch",       // replayable by anyone, in any worktree
      "target_files": ["src/slug.py"],
      "target_symbol": "slugify",
      "operator": "guard-removal",       // references/mutation-catalog.md
      "intent": "the zero-length guard never triggers",
      "expected_killers": ["tests.test_slug.TestSlugify.test_zero_max_len_returns_empty"],
      "captured_at": "2026-08-20T20:30:39+00:00",
      "claimed": {                       // MEASURED - never hand-written
        "status": "KILLED",              // KILLED | SURVIVED | TIMEOUT | UNMEASURED
        "exit_code": 1,
        "output_digest": "sha256:..."
      },
      "equivalent_justification": null   // only on a survivor no input can distinguish
    }
  ],
  "summary": { "total": 3, "claimed_killed": 3, "claimed_survived": 0 }
}
```

Hand-editing `claimed` or `summary` is the one thing that ends a round
immediately: those numbers are replayed from the patches by a process that never
reads the prose.

## verify.\<verifier\>.json

Written by `darwin verify`. The orchestrator writes `verify.orchestrator.json`;
the reviewer writes `verify.reviewer.json` from its own worktree. Identical
inputs must produce identical files — when they do not, the suite is flaky and
that finding outranks everything else in the round.

```jsonc
{
  "run_id": "...", "round": 1, "role": "implementer", "verifier": "orchestrator",
  "verified_at": "...", "head_commit": "7f70c5f...",
  "baseline": { "command": "...", "exit_code": 0, "duration_s": 0.04, "output_digest": "..." },
  "mutants": [
    {
      "id": "M1", "operator": "guard-removal", "intent": "...",
      "target_files": ["src/slug.py"],
      "claimed": "KILLED",              // what the report said
      "applied": true,
      "status": "SURVIVED",             // what actually happened
      "exit_code": 0, "duration_s": 0.03, "output_tail": "...",
      "targeted": [ { "selector": "...test_zero_max_len_returns_empty",
                      "exit_code": 0, "kills": false } ],
      "targeted_discrepancy": "named_killer_does_not_kill",
      "discrepancy": "fabricated_kill",
      "matches_claim": false
    }
  ],
  "guards": [ { "code": "G_SURVIVORS", "severity": "block", "detail": "..." } ],
  "summary": {
    "total": 3, "killed": 1, "survived": 2, "not_applicable": 0, "kill_rate": 0.333,
    "claim_mismatches": ["M1", "M3"],
    "named_killer_misses": ["M1", "M3"],
    "fabricated_kills": ["M1", "M3"],
    "blocking_guards": ["G_SURVIVORS"]
  }
}
```

## REVIEW.json

Written by the reviewer. Prose and judgement, backed by ids and paths.

```jsonc
{
  "run_id": "...", "round": 1,
  "verdict": "DISPUTE",                 // CONFIRM | DISPUTE
  "report_reproduced": true,            // did `verify` run cleanly in the reviewer's worktree
  "mutant_findings": [
    { "id": "M1", "reproduced": true, "claim_matches": false,
      "quality": "equivalent",          // strong | weak | trivial | equivalent
      "note": "the zero guard is dead code: s[:0] is already empty" }
  ],
  "adversarial_mutants": [
    { "id": "RM1", "target_file": "src/slug.py", "operator": "boundary",
      "intent": "truncation uses max_len + 1",
      "observed": { "exit_code": 0, "status": "SURVIVED" },
      "scope": "in-task",          // in-task blocks the round; beyond-task is a feature request
      "significance": "an off-by-one in truncation ships unnoticed" }
  ],
  "coverage_gaps": ["nothing pins the leading-dash trim after truncation"],
  "test_quality_issues": ["tests/test_slug.py:42 asserts on the mock, not the behaviour"],
  "dishonesty_findings": [
    { "kind": "fabricated_result",
      "evidence": "M1 and M3 claimed KILLED; both survive on replay in verify.reviewer.json" }
  ],
  "summary": "Two of three claims are fabricated; one adversarial mutant survives."
}
```

`kind` is one of `fabricated_result`, `cherry_picked_trivial`, `test_weakened`,
`mutant_touches_tests`, `unjustified_equivalent`, `tests_backfilled`. Every entry
needs checkable evidence — a mutant id, a `file:line`, a commit sha. An
accusation without one is itself a review defect, and the orchestrator has the
replay data to say so.
