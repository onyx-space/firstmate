#!/usr/bin/env python3
"""One-command self-check for spline-to-step.  Standard library only, no FreeCAD.

    python3 scripts/selfcheck.py

It checks the parts of the skill that do not need a CAD kernel:

1. the involute relations and the pin formula, against an independent tangency solve
   that resamples the flank from the involute equation and measures distances;
2. the drive rule, including that the printed module of the first example really does
   contradict the rest of its table, so driving by pitch diameter is not a preference;
3. the two example parameter tables, end to end through the schema loader and the pin
   relation: every tabulated pin dimension must land inside the band its own tabulated
   space-width limits imply;
4. the YAML-subset parser and the schema validator, including the failures they must
   refuse.

Exit status is 0 when every check passes and 1 when any fails, so CI can run it directly.
The FreeCAD-side generator is checked separately by scripts/run_freecad.sh, which needs
a FreeCAD install.
"""

import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import spline_math as sm          # noqa: E402
import spline_schema as sc        # noqa: E402

EXAMPLES = os.path.join(os.path.dirname(_HERE), "examples")

# A tabulated two-pin dimension is a measured, rounded figure, while its band comes from
# the table's own space-width limits, which are themselves rounded.  2 um is one order
# below the smallest tolerance band either example carries.
PIN_BAND_TOL_MM = 0.002
# The closed-form pin relation and the independent tangency solve share no algebra.
PIN_TANGENCY_TOL_MM = 1e-6

FAILURES = []
CHECKS = [0]


def check(label, condition, detail=""):
    CHECKS[0] += 1
    if condition:
        print("  ok   %s%s" % (label, ("  (%s)" % detail) if detail else ""))
    else:
        print("  FAIL %s%s" % (label, ("  (%s)" % detail) if detail else ""))
        FAILURES.append(label)


def close(label, actual, expected, tolerance):
    ok = abs(actual - expected) <= tolerance
    check(label, ok, "%.9f vs %.9f, diff %.3e <= %.1e"
          % (actual, expected, actual - expected, tolerance))


def section(title):
    print("\n%s" % title)


# --------------------------------------------------------------------------- #
# 1. Involute relations and the pin formula                                    #
# --------------------------------------------------------------------------- #
def check_involute():
    section("1. involute relations")
    close("inv() and its inverse round-trip at 45 deg",
          sm.inv_inverse(sm.inv(math.radians(45.0))), math.radians(45.0), 1e-12)
    close("inv() and its inverse round-trip at 10 deg",
          sm.inv_inverse(sm.inv(math.radians(10.0))), math.radians(10.0), 1e-12)
    for z, m, deg in ((32, 33.0 / 32, 45.0), (18, 1.5875, 30.0)):
        alpha = math.radians(deg)
        rb = 0.5 * z * m * math.cos(alpha)
        for kind in ("internal", "external"):
            half = sm.space_half_angle(0.5 * z * m, z, alpha, rb, kind)
            close("%s space is half the angular pitch at the pitch circle (z=%d)" % (kind, z),
                  half, math.pi / (2.0 * z), 1e-12)
            width, chord = sm.space_width_at(0.5 * z * m, z, alpha, rb, kind)
            close("%s arc space width at pitch equals pi*m/2 (z=%d)" % (kind, z),
                  width, 0.5 * math.pi * m, 1e-12)
            check("%s chord space width is below its arc width (z=%d)" % (kind, z), chord < width)


def check_pin_formula():
    section("2. pin formula against an independent tangency solve")
    cases = (
        # label, z, module, pressure angle, pin dia, flank start, flank end, kind
        ("part 1 internal", 32, 33.0 / 32, 45.0, 2.800, 16.148, 16.72625, "internal"),
        ("part 2 internal", 18, 28.575 / 18, 30.0, 3.000, 13.5325, 15.0875, "internal"),
        ("20T 20deg external", 20, 1.0, 20.0, 1.800, 20.0 * math.cos(math.radians(20.0)) / 2, 11.0, "external"),
        ("18T 30deg external", 18, 1.5875, 30.0, 3.000,
         0.5 * 18 * 1.5875 * math.cos(math.radians(30.0)), 15.0875, "external"),
    )
    for label, z, m, deg, pin, r_lo, r_hi, kind in cases:
        alpha = math.radians(deg)
        rb = 0.5 * z * m * math.cos(alpha)
        closed = sm.pin_measurement(z, m, alpha, 0.5 * math.pi * m, pin, kind)
        residual = sm.pin_tangency_residual(z, alpha, rb, closed["Rc"], kind, r_lo, r_hi, samples=100001)
        check("%s: pin of radius %.3f is tangent at the closed-form centre" % (label, pin / 2.0),
              abs(residual - pin / 2.0) <= PIN_TANGENCY_TOL_MM,
              "residual %.9f vs radius %.6f" % (residual, pin / 2.0))


# --------------------------------------------------------------------------- #
# 3. The two example parameter tables                                          #
# --------------------------------------------------------------------------- #
def pin_at(spec, width):
    return sm.pin_measurement(spec["teeth"], spec["module"],
                              spec["pressure_angle_deg"] * math.pi / 180.0,
                              width, spec["pin_diameter"], spec["kind"])["M"]


def load_example(name):
    path = os.path.join(EXAMPLES, name)
    return sc.normalize(sc.load(path), path), path


def check_examples():
    section("3. the two example parameter tables")
    part1, path1 = load_example("P1_neixinglun.yaml")
    part2, path2 = load_example("P2_huataoguan.yaml")
    mate1, _ = load_example("P1_neixinglun_mate.yaml")
    mate2, _ = load_example("P2_huataoguan_mate.yaml")

    check("the shipped samples cover both spline kinds",
          part1["kind"] == part2["kind"] == "internal"
          and mate1["kind"] == mate2["kind"] == "external")
    check("each mate carries its internal part's module, pitch and tooth count",
          mate1["module"] == part1["module"] and mate1["teeth"] == part1["teeth"]
          and mate2["module"] == part2["module"] and mate2["teeth"] == part2["teeth"])
    check("a mate's tip sits on the internal part's form diameter",
          abs(sc.mid(mate1["major_diameter"]) - part1["form_diameter"]) < 1e-9
          and abs(sc.mid(mate2["major_diameter"]) - part2["form_diameter"]) < 1e-9)
    check("a mate's root sits on the internal part's minor diameter",
          abs(sc.mid(mate1["minor_diameter"]) - sc.mid(part1["minor_diameter"])) < 1e-9
          and abs(sc.mid(mate2["minor_diameter"]) - sc.mid(part2["minor_diameter"])) < 1e-9)
    check("the sleeve keeps one missing tooth while its shaft keeps all of them",
          part2["missing_teeth"] == 1 and mate2["missing_teeth"] == 0)

    check("example 1 loads as an internal 32-tooth spline",
          part1["kind"] == "internal" and part1["teeth"] == 32)
    check("example 1 reports the module / pitch-diameter conflict",
          any("drive conflict" in note for note in part1["notes"]),
          "a printed module of 1.0 cannot reproduce a 33.000 pitch diameter over 32 teeth")
    close("example 1 is driven by the pitch diameter", part1["module"], 33.0 / 32.0, 1e-12)
    close("example 1 base circle reproduces the tabulated 23.335",
          33.0 * math.cos(math.radians(45.0)), 23.335, 5e-4)

    # The conflict is real: the printed module puts the pitch-circle space width outside
    # the table's own band, which is why the pitch diameter has to drive.
    from_module = 0.5 * math.pi * 1.0
    band = [part1["space_width"]["min_act"], part1["space_width"]["max_eff"]]
    check("a module-driven part 1 would fall outside the table's own space-width band",
          from_module < band[0] - 1e-4,
          "module 1.0 gives %.6f, the band starts at %.6f" % (from_module, band[0]))
    driven = 0.5 * math.pi * part1["module"]
    check("a pitch-diameter-driven part 1 falls inside that band",
          band[0] <= driven <= band[1],
          "%.6f inside [%.6f, %.6f]" % (driven, band[0], band[1]))

    check("example 2 loads as an internal 18-tooth spline with one tooth missing",
          part2["kind"] == "internal" and part2["teeth"] == 18
          and part2["missing_teeth"] == 1)
    check("example 2 keeps a round root with the tabulated fillet radius",
          part2["root_type"] == "round" and abs(part2["root_fillet_radius"] - 0.555625) < 1e-9)

    for spec in (part1, part2):
        limits = [value for _, value in sc.space_width_limits(spec)]
        computed = [pin_at(spec, value) for value in limits]
        band = (min(computed), max(computed))
        for table_pin in spec["over_pins"]:
            inside = band[0] - PIN_BAND_TOL_MM <= table_pin <= band[1] + PIN_BAND_TOL_MM
            check("%s: tabulated pin dimension %.3f lands in the band its own space widths imply"
                  % (spec["name"], table_pin), inside,
                  "band [%.6f, %.6f] from %s, tolerance %.4f"
                  % (band[0], band[1], ", ".join("%.3f" % v for v in limits), PIN_BAND_TOL_MM))

    # Part 2 is the tight case: the table prints its space widths as MAX ACT / MIN ACT,
    # and substituting each into the pin relation must reproduce the printed pin pair.
    close("part 2: MAX ACT 2.563 reproduces the printed pin dimension 23.832",
          pin_at(part2, 2.563), 23.832, 0.002)
    close("part 2: MIN ACT 2.532 reproduces the printed pin dimension 23.761",
          pin_at(part2, 2.532), 23.761, 0.002)


# --------------------------------------------------------------------------- #
# 4. Parser and validator                                                      #
# --------------------------------------------------------------------------- #
def check_parser():
    section("4. schema parser and validator")
    text = (
        "# leading comment\n"
        "name: demo\n"
        "kind: external        # trailing comment\n"
        "teeth: 20\n"
        "pitch_diameter: 20.0\n"
        "pressure_angle_deg: 20.0\n"
        "root_type: round\n"
        "major_diameter: [20.5, 21.0]\n"
        "minor_diameter:\n"
        "  - 18.0\n"
        "  - 18.5\n"
        "space_width:\n"
        "  min_act: 1.5\n"
        "  max_act: null\n"
        "note: 'a: b # not a comment'\n"
        "standard: ANSI B92.1b\n"
    )
    raw = sc.loads(text, "<inline>")
    check("block mapping and scalars parse", raw["teeth"] == 20 and raw["name"] == "demo")
    check("trailing comment is stripped from a value", raw["kind"] == "external")
    check("inline flow list parses", raw["major_diameter"] == [20.5, 21.0])
    check("block sequence parses", raw["minor_diameter"] == [18.0, 18.5])
    check("nested mapping parses with a null", raw["space_width"]["min_act"] == 1.5
          and raw["space_width"]["max_act"] is None)
    check("quoting protects a colon and a hash", raw["note"] == "a: b # not a comment")
    check("an unquoted multi-token string stays a string", raw["standard"] == "ANSI B92.1b")

    spec = sc.normalize(raw, "<inline>")
    check("the parsed document normalises", spec["name"] == "demo" and spec["kind"] == "external")

    def refuses(label, mutate, fragment):
        broken = dict(raw)
        mutate(broken)
        try:
            sc.normalize(broken, "<inline>")
        except sc.SchemaError as exc:
            check(label, fragment in str(exc), str(exc))
            return
        check(label, False, "no SchemaError raised")

    refuses("a missing required field is refused",
            lambda d: d.pop("pressure_angle_deg"), "required field")
    refuses("an unknown kind is refused", lambda d: d.update(kind="helical"), "'kind' must be one of")
    refuses("a boolean where a number belongs is refused",
            lambda d: d.update(teeth=True), "must be an integer")
    refuses("a path-traversal name is refused", lambda d: d.update(name="../escape"), "'name' must be")
    refuses("a pin dimension without a pin diameter is refused",
            lambda d: d.update(over_pins=[20.0]), "needs 'pin_diameter'")
    refuses("a diameter pair given the wrong way round is refused",
            lambda d: d.update(minor_diameter=[30.0, 31.0]), "must be smaller")

    # JSON takes the same path through the validator.
    import json
    spec_json = sc.loads(json.dumps(raw), "<json>")
    check("JSON documents load through the same validator", spec_json["teeth"] == 20)


def _refused(call, fragment):
    try:
        call()
    except sc.SchemaError as exc:
        return fragment in str(exc)
    return False


def check_switches():
    section("5. the space-width and pin-dimension basis switches")
    text = (
        "name: basis_demo\n"
        "kind: internal\n"
        "teeth: 18\n"
        "module: 1.5875\n"
        "pressure_angle_deg: 30.0\n"
        "root_type: round\n"
        "major_diameter: 30.175\n"
        "minor_diameter: 27.065\n"
        "form_diameter: 29.834\n"
        "space_width:\n"
        "  min_act: 2.532\n"
        "  max_act: 2.563\n"
        "pin_diameter: 3.0\n"
        "over_pins: 23.832\n"
    )
    default = sc.normalize(sc.loads(text, "<basis>"), "<basis>")
    close("the default space-width basis is the basic (zero-backlash) value",
          default["space_width_target"], 0.5 * math.pi * default["module"], 1e-12)
    check("the default pin-dimension basis is the computed value",
          default["pin_dimension_basis"] == "computed")
    close("the form diameter is carried through as a parameter",
          default["form_diameter"], 29.834, 1e-12)

    def switched(extra, body=text):
        return sc.normalize(sc.loads(body + extra, "<basis>"), "<basis>")

    max_act = switched("space_width_basis: max_act\n")
    close("switching to max_act builds at that tabulated space width",
          max_act["space_width_target"], 2.563, 1e-12)
    check("the switch records how far it departs from the basic value",
          any("wider than the basic" in note for note in max_act["notes"]))
    check("a basis with no tabulated value is refused",
          _refused(lambda: switched("space_width_basis: max_eff\n"), "needs 'space_width.max_eff'"))
    check("the drawing pin basis records the tabulated value as the one of record",
          any("pin dimension of record is the tabulated" in note
              for note in switched("pin_dimension_basis: drawing\n")["notes"]))
    without_pins = text.replace("over_pins: 23.832\n", "")
    check("the drawing pin basis is refused when the table has no two-pin value",
          _refused(lambda: switched("pin_dimension_basis: drawing\n", without_pins),
                   "needs 'over_pins'"))


def main():
    print("spline-to-step self-check")
    check_involute()
    check_pin_formula()
    check_examples()
    check_parser()
    check_switches()
    print("\n%d checks, %d failed" % (CHECKS[0], len(FAILURES)))
    if FAILURES:
        for label in FAILURES:
            print("failed: %s" % label)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
