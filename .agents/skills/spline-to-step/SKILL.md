---
name: spline-to-step
description: >-
  Turn an involute spline parameter table into a STEP solid with headless FreeCAD.
  Use when a spline parameter table has to become a 3D model or a STEP file: internal
  or external, flat or round root, module or pitch-diameter driven, optionally with
  missing teeth. Also use when the tabulated pin dimension and space width of such a
  table need checking against the involute relations.
user-invocable: false
metadata:
  internal: true
---

# spline-to-step

One involute spline parameter table in, one STEP solid out, with a summary of what was
computed against what the table said.

The script eats the schema below and nothing else.
A drawing's table is free-form, so an agent reads the drawing into the schema first;
the mapping is in "Reading a drawing table into the schema" below.

## What it produces

For a table named `P2_huataoguan` in an output directory:

- `P2_huataoguan.step` - the solid, opening with `ISO-10303-21;`.
- `check.json` - the whole record: the normalised schema, the build factors, everything
  measured off the solid, and the computed-against-tabulated comparison.
- `check.txt` - the same, as tables.

## The parameter schema

YAML is the usual form and JSON is accepted.
A JSON document is parsed with the standard library; a YAML document is parsed by a
small built-in reader that covers block mappings, nested blocks, block sequences,
inline `[a, b]` lists, single and double quotes, `#` comments, blank lines, and
`null`/`~`.
Anchors, tags, multi-line scalars and multi-document streams are refused rather than
misread, because neither the system python3 nor every FreeCAD build ships PyYAML.

Required fields, all others optional:

| Field | Meaning |
|---|---|
| `name` | file-safe part identifier; names the STEP file |
| `kind` | `internal` or `external` |
| `teeth` | tooth count, the number of positions before `missing_teeth` |
| `module` and/or `pitch_diameter` | give one, or both; see the drive rule |
| `pressure_angle_deg` | pressure angle at the pitch circle |
| `root_type` | `flat` or `round` |
| `major_diameter` | number, or `[limit, limit]` |
| `minor_diameter` | number, or `[limit, limit]` |

Optional fields:

| Field | Meaning |
|---|---|
| `root_fillet_radius` | round-root fillet radius; defaults to `0.35 * module` when a round root has none, which is an assumption and not a standard value |
| `form_diameter` | the table's T.I.F. / form diameter: the involute stops there and a straight radial root transition carries the flank to the root circle. Without it the involute runs the full flank. A value that does not lie between the root and tip diameters is refused on a flat root. |
| `space_width` | mapping with any of `min_act`, `max_act`, `max_eff`, `min_eff`, each a circular space width at the pitch circle |
| `space_width_basis` | `basic` (default) or one of the `space_width` keys: which space width the geometry is built at |
| `pin_dimension_basis` | `computed` (default) or `drawing`: which two-pin dimension is the value of record |
| `pin_diameter` | the measuring pin diameter |
| `over_pins` | number, or list of numbers: the tabulated two-pin dimension |
| `missing_teeth` | how many teeth are absent; the model keeps `teeth - missing_teeth` |
| `face_width` | axial length; defaults to 10 mm |
| `outer_diameter` | rim diameter of an internal spline; defaults to `major + 2 * 0.15 * pitch_diameter` |
| `standard`, `grade` | documentary only; carried into the summary, never used to build |

Every default and every conflict is written into the summary's `note:` lines, so a value
the table did not carry is never silent.

### Reading a drawing table into the schema

| Drawing term | Field |
|---|---|
| 件名 / part name | `name` |
| INTERNAL / EXTERNAL SPLINE, 内花键 / 外花键 | `kind` |
| 齿数 / NUMBER OF TEETH | `teeth` |
| 模数 / MODULE | `module` |
| 分度圆 / P.C.D. / 节圆 | `pitch_diameter` |
| 压力角 / PRESSURE ANGLE | `pressure_angle_deg` |
| 齿根类型 / ROOT (`Flat`, 圆齿根) | `root_type` |
| 大径 / MAJOR DIA. | `major_diameter` |
| 小径 / MINOR DIA. | `minor_diameter` |
| 成形直径 / T.I.F. DIA. | `form_diameter` |
| 齿槽宽 MIN ACT / MAX ACT / MAX EFF / MIN EFF | `space_width` |
| 量针直径 / PIN DIA. | `pin_diameter` |
| 两针距 / dimension over pins | `over_pins` |
| 缺齿，as in `18(缺一齿)` | `missing_teeth` |
| 齿宽 / face width | `face_width` |
| 花键标准 / SPLINE STANDARD | `standard` |
| 等级 / class, as in `6H` or `5` | `grade` |

Three conversions the schema does not do for you:

- A toleranced diameter such as `30.19/30.16` or `33.440-33.465` becomes a
  `[limit, limit]` pair, and the built geometry takes the midpoint. Limiting sizes are
  reached by passing the limit as a single number instead.
- An external spline's table usually gives tooth thickness `s`, not a space width.
  Convert: `e = pi * module - s`. With zero backlash `s = pi * module / 2`, so `e` is
  `pi * module / 2`.
- A table that prints the two-pin dimension as a pair prints the two limits of its
  tolerance band. Put both numbers in `over_pins`; each is compared against the pin
  dimension its own space-width value produces.

## The drive rule

A table may state a module, a pitch diameter, or both.
When both are present and the module does not reproduce the stated pitch diameter, the
pitch diameter drives the geometry (`module = pitch_diameter / teeth`) and the conflict
is reported in the summary and on stdout.
The module is never silently preferred: every other tabulated value - base circle, space
width band, pin dimension - is consistent with the pitch diameter, and a printed module
beside it is a rounded nominal.
`examples/P1_neixinglun.yaml` is exactly this case and is kept that way on purpose.

## The bases

Two switches decide which of a table's numbers the geometry and the record use, and both
default to the choice the two reference tables were signed off with.

`space_width_basis` names the space width the geometry is built at.  `basic` is the
zero-backlash value `pi * module / 2`; any of `min_act`, `max_act`, `max_eff`, `min_eff`
builds at that tabulated value instead, through a linear backlash.  A basis whose value the
table does not carry is refused rather than guessed.  The built width is measured off the
finished solid and asserted against the requested one, so a run that did not reach it fails
instead of reporting success.  FCGear's two gear classes disagree on the sign of that
backlash, so the sign that reproduces the target is chosen by measuring the flank FCGear
returns; the assertion is what keeps that choice honest.

`pin_dimension_basis` names the two-pin dimension of record.  `computed` records the value
the involute relation gives for the geometry in force, and `drawing` records the table's own
value.  Either way both numbers appear in the check summary with their difference, and the
`drawing` basis is refused when the table carries no two-pin value.

## Running it

One command, from this skill directory:

```bash
scripts/run_freecad.sh --out /tmp/out examples/*.yaml
```

That writes one STEP file per parameter table plus the check summary into `/tmp/out`.
The four shipped examples are the two internal splines of the reference drawing and the two
mating external shafts built from them, so one run exercises both kinds, a flat and a round
root, a form-diameter truncation, and a missing tooth.

`--no-verify` skips re-importing each STEP to confirm it; `--numpoints N` changes
FCGear's flank sampling density (default 160).

`run_freecad.sh` finds the headless FreeCAD by itself:

- FreeCAD on this operating system: `FreeCADCmd` or `freecadcmd` on `PATH`, or
  `FREECADCMD` pointing at it. Paths are passed through unchanged.
- WSL driving the Windows-side FreeCAD: `freecadcmd.exe` under
  `/mnt/c/Users/*/AppData/Local/Programs/FreeCAD*/bin/`. A WSL path cannot be handed to
  a Windows process, so the scripts and the specs are staged into the Windows temp
  directory, run there, and the artifacts copied back into `--out`. The launcher sets
  `WSL_INTEROP` when it is missing, which `freecadcmd.exe` needs and fails without.

`freecadcmd` treats every bare argument as a file to open, so a direct invocation has to
put the separator `--pass` before the script's own arguments:

```bash
FreeCADCmd scripts/gen_step.py --pass --out /tmp/out examples/P1_neixinglun.yaml
```

The generator needs the FCGear workbench, whose `InternalInvoluteGear` and
`InvoluteGear` supply the involute flanks.

## What the geometry does

FCGear closes the ends of its flanks with straight chords, and a chord sits
`r * (1 - cos(half_span))` inside its circle - 6 um to 24 um on these parts, on the two
diameters that mate.
Both chords are replaced with arcs, so the major and minor diameters are true cylinders.
When the table names a form diameter, the involute stops on it and a straight radial root
transition carries the flank to the root circle.
On an internal spline the root circle is the major diameter and the tip circle is the minor
diameter, so there the transition runs from the form diameter outward to the major diameter.
On an external spline the root circle is the minor diameter and the tip circle is the major
diameter, so there it runs from the form diameter inward to the minor diameter.
A round root is filleted at both root corners.
An internal spline is the outer cylinder minus the profile prism; an external spline is
the profile prism itself.
A missing tooth is cut out with a wedge: an internal one out to its root circle so the
rim behind it stays whole, an external one from the root circle upwards.

### A mating part

The two `*_mate.yaml` examples are external spline shafts for the two internal splines.
They take their tooth count, module, pitch diameter, pressure angle, and root type from the
internal part, and derive their diameters from that part's own limiting diameters: the tip
lands on the internal form diameter, because past it the internal flank is no longer an
involute, and the root lands on the internal minor diameter, so the two are the nominal
zero-clearance pair.

The sleeve's absent tooth is not copied to its shaft: an absent tooth removes material, so it
only widens the void by one pitch, and the shaft keeps its full tooth count and gains
clearance there instead.
Both parts are in phase by construction, because FCGear centres an internal spline's first
tooth space and an external spline's first tooth on the same axis, and the absent tooth is
removed a half pitch beyond the tooth space nearest that axis.

## Checking it

One command, no FreeCAD needed, exits non-zero on any failure:

```bash
python3 scripts/selfcheck.py
```

It checks the involute relations, then the pin formula against an independent tangency
solve that resamples the flank from the involute equation, then both example tables: each
tabulated pin dimension must land inside the band its own tabulated space-width limits
imply, and part 2's printed pair must come back within 2 um.
It also pins the parser and the validator, including the failures they must refuse.

`check.txt` from a generation run is the other half of the check: the same closed-form
values against the values measured off the built solid.
Its `pin_tangency_residual` is the distance from the closed-form pin centre to the
generated flank, so it equals the pin radius exactly when the built geometry agrees with
the formula, and section 2 of the self-check asserts the same identity without FreeCAD.

## What this skill does not do

It produces one nominal solid at the space width the selected basis names, the zero-backlash
basic value by default, and nothing else.
Tolerance zones, grade (`6H`, `class 5`), and fit (`大径配合`, major-diameter fit) are a
separate tolerance system: the ACT/EFF values on a table are limits of a band, not the
nominal shape, and this skill neither expands them into deviations nor guarantees a
part that meets the grade.
It does build the mating part's spline geometry, but not its outer shape, heat treatment,
material, or gauges.

Known approximations, all recorded in the summary:

- A flat root's form diameter is modelled exactly: the involute stops there and a straight
  radial transition reaches the root circle.  A round root ends its involute with the fillet
  instead, so there the table's form diameter is compared against the fillet and
  `root_fillet_radius` is what moves it; because a fillet is tangent to the involute, that
  measured boundary is tolerance-dependent - it is where the flank's departure from the true
  involute first exceeds 1e-4 rad - and a difference of a tenth of a millimetre against the
  table is normal rather than a defect.
- A missing tooth's angular position is not on the table, which carries no datum for it; the
  removed teeth are consecutive from the tooth a half pitch beyond the tooth space nearest
  the +X axis, the same position on every run.
- `outer_diameter` sizes the rim of an internal spline only and does not touch the spline
  geometry; a default is applied and reported when the table has none.
- A mating part's diameters are derived, not tabulated: tip on the internal part's form
  diameter and root on its minor diameter, at zero clearance.
- The two-pin relation is `inv(alpha_c) = inv(alpha) +/- e/d -/+ pin_dia/d_b`, and the
  reported dimension is the gap between the pins' facing surfaces for an internal spline
  (`2*Rc - pin_dia`) and across the pins for an external one (`2*Rc + pin_dia`). That
  convention reproduces a tabulated internal two-pin pair to 2 um; a table using another
  convention needs its numbers re-derived with the relation stated here.
- FCGear's backlash is what turns a space-width basis into geometry, and FCGear's two gear
  classes do not agree on its sign; the sign that reaches the requested width is chosen by
  measurement and the width of the finished solid is asserted against the request.

## Files

| Path | Role |
|---|---|
| `scripts/spline_math.py` | closed-form involute and pin relations, standard library only |
| `scripts/spline_schema.py` | schema loading, validation, drive resolution, defaults |
| `scripts/gen_step.py` | runs inside FreeCAD: builds the solid, exports STEP, writes the summary |
| `scripts/run_freecad.sh` | finds and drives a headless FreeCAD, including the WSL-to-Windows case |
| `scripts/selfcheck.py` | the FreeCAD-free one-command check |
| `examples/*.yaml` | the two internal tables from the reference drawing and the two mating external shafts, covering both kinds and both root types |
