# spline-to-step — live evidence

Product: `.agents/skills/spline-to-step` — an involute spline parameter table in, a STEP
solid out. Driven live through headless FreeCAD 1.1.3 (Windows-side `freecadcmd.exe` from
WSL, the launcher's own WSL path) plus the FreeCAD-free `selfcheck.py`.

## 1. One command, four reference parts → four STEP files

    scripts/run_freecad.sh --out /tmp/spline-out \
        examples/P1_neixinglun.yaml examples/P1_neixinglun_mate.yaml \
        examples/P2_huataoguan.yaml examples/P2_huataoguan_mate.yaml

exit 0. Each artifact opens with `ISO-10303-21;`, and each STEP round-trips to a solid of
the same volume (re-imported volume == built volume):

| part | kind | teeth (spec / in section) | root | volume mm3 | round-trip |
|---|---|---|---|---|---|
| P1_neixinglun | internal | 32 / 32 | flat | 6684.606 | 6684.606 |
| P1_neixinglun_mate | external | 32 / 32 | flat | 8446.058 | 8446.058 |
| P2_huataoguan | internal | 18 / 17 | round | 4872.777 | 4872.777 |
| P2_huataoguan_mate | external | 18 / 18 | round | 6388.563 | 6388.563 |

Run log: `run_freecad_examples.log`; summary: `check_examples.txt` / `check_examples.json`.
Projected XY outlines of the four built solids: `splines-projection.png` (from
`splines-projection.svg`).

## 2. The captain's口径, measured off the built solid

| item | P1_neixinglun | P2_huataoguan |
|---|---|---|
| drive rule | pitch 33.000 drives -> module 1.031250 (printed 1.0 conflict reported) | module 1.5875 and pitch 28.575 agree |
| D1 space width in force (basic) | 1.619884 | 2.493639 |
| D6 pin dimension of record (computed) | 27.759842 (drawing 27.778, delta 18 um) | 23.672659 |
| D3 form diameter (T.I.F.) | measured 33.140000 (table 33.140000) | - (round root uses fillet) |
| D4 root fillet | 0 (flat) | 0.5556 = 0.35*m |
| D5 mate tip / root | 33.140 / 32.296 = internal form / internal minor | 29.834 / 27.065 = internal form / internal minor |

P2's tabulated pair is reproduced at the table's own space widths (self-check): MAX ACT
2.563 -> 23.830809 (printed 23.832, delta 1.19 um) and MIN ACT 2.532 -> 23.760809 (printed
23.761, delta 0.19 um), both inside the 2 um the captain asked for.

## 3. Basis switch (D1/D6 made switchable)

`space_width_basis: max_act` on P2 (`/tmp/variants/P2_maxact.yaml`) -> the solid is built at
2.563002 (target 2.563) and the *pin dimension of record* is computed at that same width,
23.830809 - not the basic 23.672659. Evidence: `check_variants.txt` / `.json`.

A basis the table does not carry is refused rather than guessed (live loader):

    space_width_basis=min_eff, no min_eff   -> REFUSED: needs 'space_width.min_eff'
    pin_dimension_basis=drawing, no over_pins -> REFUSED: needs 'over_pins'
    space_width_basis=nonsense              -> REFUSED: must be one of basic/min_act/max_act/max_eff/min_eff

## 4. Adversarial: the two-pin "band" row tells the truth

Spec with `over_pins: [25.0]`, far outside the band 23.673496 .. 23.830809:

- before fix (`check_before_fix.txt`, `P2_outofband`):
  `pin dimension inside the band ... | table=25.000000 computed=25.000000 diff=0.000000`
  - asserts a 25 mm pin is "inside" a band it misses by 1.17 mm.
- after fix (`check_variants.txt`, `P2_outofband`):
  `pin dimension against the band ... | table=25.000000 computed=23.830809 diff=-1.169191`
  - the row now reports how far outside it lies.

## 5. Regression: before the review fix vs. after

Same FreeCAD 1.1.3, same specs, old `gen_step.py` from c0ff8c3 vs. the change at bbed5eb.

| case | before (`check_before_fix.*`) | after (`check_variants.*`) |
|---|---|---|
| P2 `space_width_basis: max_act`, pin of record | 23.672659 (computed at the basic width, while the solid was built at 2.563) | 23.830809 (computed at 2.563) |
| P2 `over_pins: [25.0]`, band row | "inside the band", diff 0 | "against the band", diff -1.169191 |
| P1 built volume, flat-root T.I.F. flank | 6684.496 mm3 | 6684.606 mm3 (flank now ends exactly on the T.I.F. before the radial transition) |

The form-diameter cut changes the built geometry (volume differs) even though P1's
`involute_form_diameter` measurement rounds to the same 33.140 in both.

## 6. FreeCAD-free self-check and the repository test

`python3 scripts/selfcheck.py` -> 59 checks, 0 failed, including both reference tables'
pin values landing in their own bands and P2's printed pair back within 2 um.
`bash tests/fm-spline-to-step.test.sh` -> all 3 tests ok.
