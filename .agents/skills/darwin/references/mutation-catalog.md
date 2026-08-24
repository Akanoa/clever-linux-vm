# Mutation catalog

A mutant is a *simulated defect*. The question it answers is always the same:
**if someone shipped this bug, would the suite notice?**

The operator name goes in `--operator`, the plain-language bug in `--intent`.
Both are read by the reviewer, who grades whether the mutant was worth writing.

## Operators worth using

| operator | edit | the bug it imitates |
|---|---|---|
| `boundary` | `<` ↔ `<=`, `n` → `n-1`, `>= 0` → `> 0` | off-by-one, wrong inclusivity |
| `conditional` | invert a condition, drop a clause, `&&` → `\|\|` | mishandled edge case |
| `guard-removal` | delete a validation or early return | unvalidated input reaching the core |
| `arithmetic` | `+` ↔ `-`, `*` ↔ `/`, drop a modulo | wrong formula |
| `return-value` | return the other branch, a stale variable, `null`/`None` | wrong result on one path |
| `default-value` | change a default parameter or fallback | wrong behaviour when a caller omits an argument |
| `state-update` | skip an assignment, update the wrong field, mutate a copy | lost write, stale state |
| `side-effect` | skip a save/emit/log/close, reorder two effects | silent data loss, leak |
| `error-handling` | swallow an exception, catch too broadly, drop a re-raise | failures reported as success |
| `collection` | `first` → `last`, off-by-one slice, drop a filter, unstable sort | wrong element, wrong subset |
| `async-order` | drop an `await`, swap two awaited calls, remove a lock | race, unhandled rejection |
| `type-coercion` | `==` ↔ `===`, string vs number compare, silent cast | comparison that lies |
| `null-handling` | remove a nil check, return empty instead of absent | crash or wrong empty case |
| `config-flag` | invert a feature flag or an option default | the feature is off in production |

## What does not count

These are rejected on sight — by `mutant capture`, by the reviewer, or by both:

- **Editing a test.** Mutants change production code. Nothing else.
- **Vandalism.** Deleting a function body, breaking the syntax, renaming a symbol
  so the module fails to import. Every test dies, so nothing is proven.
- **Unreached code.** Mutating a line the new tests never execute. If you cannot
  make it fail, it is not evidence about your tests.
- **Cosmetics.** Comments, whitespace, log text nobody asserts on, variable names.
- **Redundant clones.** Five boundary mutants on the same comparison is one
  mutant, counted five times. Cover five *behaviours* instead.

## Choosing the set

One mutant per behaviour the task added or changed, minimum. Then ask, per
behaviour: which single edit would a reviewer most want the suite to catch?
That one is worth writing.

Aim at:
- the branch you added, in its non-obvious direction
- the boundary you chose (why `<=` and not `<`?)
- the error path, not only the happy path
- the side effect, not only the return value
- what the caller relies on that the function only implies

## Surviving mutants

A survivor is the whole point of the exercise: it names a defect your tests
cannot see. Add the test that kills it and re-measure. Never delete the mutant to
tidy the numbers — the report's job is to show the gap and its closure.

The single legitimate exception is an **equivalent mutant**: one no input can
distinguish from the original.

```python
if max_len == 0:       # mutating this to `== -99` changes nothing:
    return ""          # s[:0] is already "" further down
```

That is not a testing gap, it is dead code. Record
`equivalent_justification` explaining why no input can tell the difference — and
expect the reviewer to try to construct one. Usually the better fix is to delete
the redundant code, which makes the mutant impossible instead of merely
unkillable.

## Naming killers

`--expected-killers` takes the selectors of the tests that must fail, in the
project's own syntax:

```
pytest       tests/test_slug.py::TestSlug::test_rejects_empty
unittest     tests.test_slug.TestSlug.test_rejects_empty
jest/vitest  -t "rejects empty input"
go           -run TestSlug/rejects_empty
cargo        slug::tests::rejects_empty
```

Configure the matching `test.single_command` (with a `{selector}` placeholder)
and the verifier will run exactly those tests against the mutant. Without it,
"the suite went red" is all anyone can check, and a mutant killed by an
unrelated flaky test looks identical to a mutant killed by the test you wrote.
