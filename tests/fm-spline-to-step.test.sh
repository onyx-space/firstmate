#!/usr/bin/env bash
# Behavior tests for the spline-to-step skill's FreeCAD-free self-check.
#
# The generator itself needs a FreeCAD install with the FCGear workbench, which CI does
# not have, so this covers the half that does not need a CAD kernel: the involute and pin
# relations, the drive rule, the schema loader, and both reference parameter tables.
# scripts/run_freecad.sh drives the other half wherever FreeCAD exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/spline-to-step"

test_selfcheck_passes() {
  local out status
  out=$(python3 "$SKILL/scripts/selfcheck.py" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "selfcheck.py exited $status: $out"
  assert_contains "$out" "0 failed" "self-check did not report a clean pass"
  assert_contains "$out" "tabulated pin dimension 23.761 lands in the band" \
    "the second part's pin dimension was not checked against its own band"
  pass "spline-to-step: the FreeCAD-free self-check passes"
}

test_examples_normalise() {
  local out status
  out=$(python3 - "$SKILL" <<'PY' 2>&1
import json, os, sys
skill = sys.argv[1]
sys.path.insert(0, os.path.join(skill, "scripts"))
import spline_schema as schema
report = {}
for name in sorted(os.listdir(os.path.join(skill, "examples"))):
    path = os.path.join(skill, "examples", name)
    spec = schema.normalize(schema.load(path), path)
    report[spec["name"]] = {
        "kind": spec["kind"],
        "teeth": spec["teeth"],
        "module": round(spec["module"], 6),
        "pitch_diameter": spec["pitch_diameter"],
        "missing_teeth": spec["missing_teeth"],
        "conflict": any("drive conflict" in note for note in spec["notes"]),
    }
print(json.dumps(report, sort_keys=True))
PY
)
  status=$?
  [ "$status" -eq 0 ] || fail "loading the example tables failed: $out"
  assert_contains "$out" '"P1_neixinglun": {"conflict": true, "kind": "internal", "missing_teeth": 0, "module": 1.03125, "pitch_diameter": 33.0, "teeth": 32}' \
    "the first example did not resolve to a pitch-diameter-driven internal spline with its conflict recorded"
  assert_contains "$out" '"P2_huataoguan": {"conflict": false, "kind": "internal", "missing_teeth": 1, "module": 1.5875, "pitch_diameter": 28.575, "teeth": 18}' \
    "the second example did not resolve to an 18-position internal spline with one tooth missing"
  pass "spline-to-step: the example tables normalise to the expected parts"
}

test_launcher_requires_out() {
  local out status
  out=$(bash "$SKILL/scripts/run_freecad.sh" examples/P1_neixinglun.yaml 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "run_freecad.sh without --out exited $status, expected 2"
  assert_contains "$out" "--out DIR is required" "the launcher did not say what was missing"
  pass "spline-to-step: the launcher refuses a run with no output directory"
}

test_selfcheck_passes
test_examples_normalise
test_launcher_requires_out
