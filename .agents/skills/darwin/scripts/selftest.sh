#!/usr/bin/env bash
# End-to-end smoke test for darwin: builds a throwaway repo, runs an honest
# round to PASS and a dishonest one to REVISE, and checks the guards fire.
# Usage: scripts/selftest.sh [workdir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DARWIN="python3 $HERE/darwin.py"
WORK="${1:-$(mktemp -d)}/darwin-selftest"
PASSED=0

# a failed assertion exits early, so tear down from a trap rather than the
# happy path - otherwise a broken run leaves worktrees and herdr workspaces behind
cleanup() {
  local rc=$?
  [ "$rc" = "0" ] || { [ -d "$WORK" ] && $DARWIN --cwd "$WORK" clean --delete-branches >/dev/null 2>&1; }
  return $rc
}
trap cleanup EXIT

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASSED=$((PASSED+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2"; }

rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/tests"; cd "$WORK"
git init -q .; git config user.email darwin@example.com; git config user.name darwin
printf '__pycache__/\n*.pyc\n' > .gitignore
touch src/__init__.py tests/__init__.py
cat > src/cart.py <<'EOF'
def total(items, discount=0.0):
    subtotal = sum(i["price"] * i["qty"] for i in items)
    return round(subtotal * (1 - discount), 2)
EOF
cat > tests/test_cart.py <<'EOF'
import unittest
from src.cart import total


class TestTotal(unittest.TestCase):
    def test_sums_line_items(self):
        self.assertEqual(total([{"price": 2.0, "qty": 3}]), 6.0)
EOF
cat > darwin.config.json <<'EOF'
{"test": {"command": "python3 -m unittest discover -q -s . -p \"test_*.py\"",
          "single_command": "python3 -m unittest -q {selector}"},
 "mutation": {"min_mutants": 2},
 "agents": {"implementer": {"provider": "inline"}, "reviewer": {"provider": "inline"}}}
EOF
git add -A; git commit -qm "base"

echo "== setup"
$DARWIN doctor >/dev/null || true
$DARWIN init --task "Reject a discount outside [0, 1); a missing qty counts as 1" > init.json
RUN=$(jget init.json "d['run_id']")
[ -n "$RUN" ] && ok "init created run $RUN" || fail "init"
$DARWIN worktree add --role implementer > wt.json
WT=$(jget wt.json "d['worktree']")
[ -d "$WT" ] && ok "implementer worktree isolated ($(jget wt.json "d['isolation']"))" || fail "worktree"

echo "== implementer: red -> green"
cd "$WT"
cat >> tests/test_cart.py <<'EOF'

    def test_rejects_discount_of_one(self):
        with self.assertRaises(ValueError):
            total([{"price": 1.0, "qty": 1}], discount=1.0)

    def test_missing_qty_counts_as_one(self):
        self.assertEqual(total([{"price": 4.5}]), 4.5)
EOF
if python3 -m unittest discover -q -s . -p "test_*.py" >/dev/null 2>&1; then fail "tests should be red first"; fi
ok "new tests fail before the code exists"
git add -A; git commit -qm "red: discount bounds and default qty"
cat > src/cart.py <<'EOF'
def total(items, discount=0.0):
    if discount < 0 or discount >= 1:
        raise ValueError("discount must be in [0, 1)")
    subtotal = sum(i["price"] * i.get("qty", 1) for i in items)
    return round(subtotal * (1 - discount), 2)
EOF
python3 -m unittest discover -q -s . -p "test_*.py" >/dev/null 2>&1 || fail "suite should be green after the fix"
ok "suite green after the implementation"
git add -A; git commit -qm "green: discount bounds and default qty"

echo "== mutants"
sed -i 's/    if discount < 0 or discount >= 1:/    if discount < 0 or discount > 1:/' src/cart.py
$DARWIN mutant capture --role implementer --round 1 --id M1 --operator boundary --symbol total \
  --intent "upper bound made inclusive" \
  --expected-killers "tests.test_cart.TestTotal.test_rejects_discount_of_one" >/dev/null
sed -i 's/i.get("qty", 1)/i.get("qty", 0)/' src/cart.py
$DARWIN mutant capture --role implementer --round 1 --id M2 --operator default-value --symbol total \
  --intent "missing qty defaults to 0 and drops the line item" \
  --expected-killers "tests.test_cart.TestTotal.test_missing_qty_counts_as_one" >/dev/null
[ -z "$(git status --porcelain)" ] && ok "capture reverted the working tree" || fail "capture left the tree dirty"
sed -i 's/self.assertEqual(total(\[{"price": 2.0, "qty": 3}\]), 6.0)/pass/' tests/test_cart.py
if $DARWIN mutant capture --role implementer --round 1 --id BAD --operator conditional \
     --intent "mutating a test" >/dev/null 2>&1; then fail "a mutant editing tests must be rejected"; fi
ok "mutants that edit tests are refused"
git checkout -- tests/test_cart.py
$DARWIN mutant run --role implementer --round 1 >/dev/null
$DARWIN report build --role implementer --round 1 --baseline >/dev/null
RD="$WORK/.darwin/runs/$RUN/rounds/r1"
[ "$(jget "$RD/implementer/MUTATION-REPORT.json" "d['summary']['claimed_killed']")" = "2" ] \
  && ok "both mutants measured as killed" || fail "report build"

echo "== an unauthored report is caught"
$DARWIN verify --role implementer --round 1 --verifier skeleton >/dev/null
[ "$(jget "$RD/implementer/verify.skeleton.json" "'G_REPORT_INCOMPLETE' in d['summary']['blocking_guards']")" = "True" ] \
  && ok "the generated skeleton alone is rejected as unauthored" || fail "G_REPORT_INCOMPLETE"
python3 - "$RD/implementer/MUTATION-REPORT.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["tests_added"] = [{"file": "tests/test_cart.py", "name": "test_rejects_discount_of_one",
                     "covers": "discount == 1 is rejected"},
                    {"file": "tests/test_cart.py", "name": "test_missing_qty_counts_as_one",
                     "covers": "a missing qty counts as 1"}]
d["red_evidence"] = [{"behaviour": "discount bounds and default qty", "test": "test_rejects_discount_of_one",
                      "exit_code": 1, "excerpt": "ValueError not raised"}]
d["narrative"] = "M1 probes the upper bound, M2 the qty default; each dies against its named test."
json.dump(d, open(p, "w"), indent=2)
EOF

echo "== dishonest round is caught"
python3 - "$RD/implementer/MUTATION-REPORT.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["_honest_backup"] = json.loads(json.dumps(d["mutants"]))
d["mutants"][1]["patch"] = "mutants/M1.patch"          # M2 now replays M1's patch
d["mutants"][1]["claimed"]["status"] = "KILLED"
json.dump(d, open(p, "w"), indent=2)
EOF
$DARWIN verify --role implementer --round 1 --verifier orchestrator >/dev/null
V="$RD/implementer/verify.orchestrator.json"
[ "$(jget "$V" "len(d['summary']['named_killer_misses'])")" -ge 1 ] \
  && ok "a mutant its named test cannot kill is flagged" || fail "named killer check"
python3 - "$RD/implementer/MUTATION-REPORT.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["mutants"] = d.pop("_honest_backup")
for m in d["mutants"]:
    m["claimed"]["status"] = "KILLED"
json.dump(d, open(p, "w"), indent=2)
EOF

echo "== honest round verifies"
$DARWIN verify --role implementer --round 1 --verifier orchestrator >/dev/null
[ "$(jget "$V" "d['summary']['kill_rate']")" = "1.0" ] && ok "every claim reproduces" || fail "verify"
[ "$(jget "$V" "d['summary']['blocking_guards']")" = "[]" ] && ok "no blocking guards" || fail "guards fired: $(jget "$V" "d['summary']['blocking_guards']")"
$DARWIN verify --role implementer --round 1 --verifier repeat >/dev/null
[ "$(jget "$RD/implementer/verify.repeat.json" "[m['status'] for m in d['mutants']]")" \
  = "$(jget "$V" "[m['status'] for m in d['mutants']]")" ] \
  && ok "replay is deterministic across runs" || fail "non-deterministic replay"

echo "== reviewer"
$DARWIN worktree add --role reviewer >/dev/null
$DARWIN verify --run "$RUN" --role reviewer --round 1 \
  --report "$RD/implementer/MUTATION-REPORT.json" --verifier reviewer \
  --out "$RD/reviewer/verify.reviewer.json" >/dev/null
[ "$(jget "$RD/reviewer/verify.reviewer.json" "d['summary']['kill_rate']")" = "1.0" ] \
  && ok "reviewer reproduces the same result in its own worktree" || fail "reviewer verify"
cat > "$RD/reviewer/REVIEW.json" <<EOF
{"run_id":"$RUN","round":1,"verdict":"CONFIRM","report_reproduced":true,
 "mutant_findings":[],"adversarial_mutants":[],"coverage_gaps":[],
 "test_quality_issues":[],"dishonesty_findings":[],"summary":"reproduced"}
EOF
$DARWIN judge --round 1 > judge.json
[ "$(jget judge.json "d['recommendation']")" = "PASS" ] && ok "judge recommends PASS" || fail "judge said $(jget judge.json "d['recommendation']")"

echo "== a disputed round is REVISE, repeated fabrication escalates"
cat > "$RD/reviewer/REVIEW.json" <<EOF
{"run_id":"$RUN","round":1,"verdict":"DISPUTE","report_reproduced":true,
 "mutant_findings":[],"adversarial_mutants":[{"id":"RM1","intent":"off-by-one","observed":{"status":"SURVIVED"}}],
 "coverage_gaps":[],"test_quality_issues":[],
 "dishonesty_findings":[{"kind":"cherry_picked_trivial","evidence":"M2"}],"summary":"disputed"}
EOF
$DARWIN judge --round 1 --record REVISE --reason "reviewer disputes" > judge2.json
[ "$(jget judge2.json "d['recommendation']")" = "REVISE" ] && ok "dispute + surviving attack blocks the round" || fail "judge2"
$DARWIN escalate --round 1 --reason "selftest" >/dev/null
[ -f "$WORK/.darwin/runs/$RUN/ESCALATION.md" ] && ok "escalation writes a human-review request" || fail "escalate"

echo "== land and clean"
$DARWIN land --strategy patch --force >/dev/null
[ -s "$WORK/.darwin/runs/$RUN/RESULT.patch" ] && ok "land exported a patch" || fail "land"
$DARWIN clean --delete-branches >/dev/null
[ "$(git -C "$WORK" worktree list | wc -l)" = "1" ] && ok "clean removed every worktree" || fail "clean"

printf '\n\033[32m%d checks passed\033[0m  (artefacts in %s)\n' "$PASSED" "$WORK"
