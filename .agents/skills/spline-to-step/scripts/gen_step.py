"""Build involute spline solids from a parameter-table schema and export STEP.

Runs inside headless FreeCAD, because it needs FreeCAD's kernel and the FCGear
workbench.  It never runs a GUI and never writes outside ``--out``.

    FreeCADCmd gen_step.py --pass --out DIR spec.yaml [spec2.yaml ...]
    scripts/run_freecad.sh --out DIR spec.yaml          # WSL driving Windows FreeCAD

From WSL the Windows-side interpreter is `freecadcmd.exe`; see scripts/run_freecad.sh,
which also sets the WSL_INTEROP handle freecadcmd.exe needs.

Per spec it writes, into --out:

    <name>.step        ISO-10303-21 solid
    check.json         machine-readable build/measure/compare record
    check.txt          the same, as a readable table of computed vs tabulated values

How the profile is made
-----------------------
1. FCGear's InternalInvoluteGear (internal) or InvoluteGear (external) generates one
   tooth space / one tooth.  Its `head` and `clearance` factors are solved so its two
   truncation circles land exactly on the table's major and minor diameters.
2. FCGear closes the ends of those flanks with straight CHORDS.  A chord sits
   r*(1 - cos(half_span)) inside its circle, which for these parts is 6 um to 24 um of
   error on the two diameters that mate.  Both chords are replaced here by arcs of the
   same radius, so the major and minor diameters are true cylinders.
3. When the table names a form diameter and the root is flat, the involute stops there and a
   straight radial transition carries the flank out to the root circle.  A round root already
   ends the involute with its fillet, and the table's form diameter is compared against it.
4. The tooth space is built at the space width the table's basis names: the basic
   (zero-backlash) value, or one of the tabulated ACT/EFF values through a linear backlash.
5. A round root is filleted at both root corners with FCGear's own fillet helper.
6. The profile is repeated once per tooth.  An internal spline is the outer cylinder
   minus the profile prism; an external spline is the profile prism itself.
7. Missing teeth are removed with a wedge cut: an internal tooth is cut out to its root
   circle so the rim behind it stays whole, an external tooth is cut out from the root
   circle upwards.

Everything this file prints or records as an assumption is a value the parameter table
did not carry; none of it is silent.
"""

import argparse
import json
import math
import os
import sys
import traceback

import FreeCAD as App
import Part

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import spline_math as sm          # noqa: E402
import spline_schema as sc        # noqa: E402

D2R = math.pi / 180.0
NUMPOINTS = 160
SAMPLE_PER_MM = 400.0
STEP_HEADER = "ISO-10303-21"


# --------------------------------------------------------------------------- #
# Geometry                                                                     #
# --------------------------------------------------------------------------- #
def _v(point):
    return App.Vector(float(point[0]), float(point[1]), 0.0)


def _radius(point):
    return math.hypot(float(point[0]), float(point[1]))


def _spline_edge(points):
    curve = Part.BSplineCurve()
    curve.interpolate([_v(p) for p in points])
    return curve.toShape()


def _arc(start, end, radius):
    """Minor circular arc of the given radius from start to end, centred on the origin."""
    mx = 0.5 * (start.x + end.x)
    my = 0.5 * (start.y + end.y)
    norm = math.hypot(mx, my)
    if norm < 1e-12:
        raise RuntimeError("arc endpoints are diametrically opposite")
    mid = App.Vector(radius * mx / norm, radius * my / norm, 0.0)
    return Part.Edge(Part.Arc(start, mid, end))


def truncation_factors(spec, module):
    """FCGear `head`/`clearance` that put the truncation circles on the table's diameters.

    InternalInvoluteGear swaps them on the way in (obj.head -> gear.clearance), and the
    two kinds reach their diameters from opposite ends, so each kind reads the same two
    solved values in the other order.
    """
    d = spec["pitch_diameter"]
    d_major = sc.mid(spec["major_diameter"])
    d_minor = sc.mid(spec["minor_diameter"])
    addendum = (d_major - d - 2.0 * module) / (2.0 * module)
    dedendum = (d - 2.0 * module - d_minor) / (2.0 * module)
    if spec["kind"] == "internal":
        return dedendum, addendum
    return addendum, dedendum


def gear_source(spec, module, head_factor, clearance_factor, numpoints):
    from freecad.gears.involutegear import InvoluteGear
    from freecad.gears.internalinvolutegear import InternalInvoluteGear

    factory = InternalInvoluteGear if spec["kind"] == "internal" else InvoluteGear
    doc = App.newDocument("spline_src")
    obj = doc.addObject("Part::FeaturePython", "fcgear_source")
    factory(obj)
    obj.num_teeth = spec["teeth"]
    obj.module = module
    obj.pressure_angle = spec["pressure_angle_deg"]
    obj.shift = 0.0
    obj.backlash = 0.0
    obj.reversed_backlash = False
    obj.head_fillet = 0.0
    obj.root_fillet = 0.0
    obj.head = head_factor
    obj.clearance = clearance_factor
    obj.numpoints = numpoints
    # We want FCGear's gear parameters and its involute sampler, not the solid it builds
    # from them - this file assembles the profile itself.  Its simple branch skips that
    # build and still runs the parameter update first, so recompute() stays cheap.
    obj.simple = True
    doc.recompute()
    return doc, obj


def space_width_from_gear(gear, spec):
    """Circular space width at the pitch circle, read off FCGear's own flank samples."""
    radius = 0.5 * spec["pitch_diameter"]
    for segment in gear.points(num=160):
        points = [(float(p[0]), float(p[1])) for p in segment]
        for index in range(len(points) - 1):
            r0 = _radius(points[index])
            r1 = _radius(points[index + 1])
            if (r0 - radius) * (r1 - radius) > 0 or r0 == r1:
                continue
            fraction = (radius - r0) / (r1 - r0)
            x = points[index][0] + fraction * (points[index + 1][0] - points[index][0])
            y = points[index][1] + fraction * (points[index + 1][1] - points[index][1])
            half = abs(math.atan2(y, x))
            if spec["kind"] == "external":
                half = math.pi / spec["teeth"] - half
            return 2.0 * radius * half
    raise RuntimeError("could not read a space width at the pitch circle from FCGear")


def apply_space_width(spec, source, doc):
    """Build the geometry at the space width the table's basis names.

    FCGear widens a tooth space through a linear backlash, but its two gear classes do not
    agree on the sign, so the sign that reproduces the target is picked by measuring the
    flank FCGear itself returns.  The achieved width is asserted against the target after
    the solid is built, so this selection cannot pass unnoticed if it is wrong.
    """
    target = spec["space_width_target"]
    achieved = space_width_from_gear(source.gear, spec)
    delta = target - achieved
    if abs(delta) < 1e-9:
        return
    for candidate in (delta, -delta):
        source.backlash = candidate
        doc.recompute()
        achieved = space_width_from_gear(source.gear, spec)
        if abs(achieved - target) <= 1e-2:
            return
    raise RuntimeError(
        "cannot build a tooth space %.6f mm wide at the pitch circle: a backlash of %.6f mm "
        "reaches %.6f. The space width basis '%s' may be out of reach for this geometry."
        % (target, delta, achieved, spec["space_width_basis"]))


def root_radius(spec):
    """The circle a root fillet sits on: an internal spline's root is its major diameter,
    an external spline's root is its minor diameter."""
    pair = spec["major_diameter"] if spec["kind"] == "internal" else spec["minor_diameter"]
    return 0.5 * sc.mid(pair)


def _line(start, end):
    return Part.Edge(Part.LineSegment(App.Vector(start[0], start[1], 0.0),
                                       App.Vector(end[0], end[1], 0.0)))


def _on_circle(point, radius):
    """The point at the same polar angle as ``point`` but on the given radius."""
    angle = math.atan2(point[1], point[0])
    return (radius * math.cos(angle), radius * math.sin(angle))


def _crossing(start, end, radius):
    """The point where the segment between two points reaches the given radius."""
    r0 = _radius(start)
    r1 = _radius(end)
    fraction = (radius - r0) / (r1 - r0)
    return (start[0] + fraction * (end[0] - start[0]),
            start[1] + fraction * (end[1] - start[1]))


def _cut_at_radius(points, form_radius, tip_side):
    """Keep the tip-side part of one radius-monotone flank polyline.

    The polyline may run either way, so the form diameter can cut it at the start (a flank
    walking from the root toward the tip) or at the end.  Returns (kept_points, cut_point):
    kept_points is None when the whole segment lies root-side, and cut_point is None when it
    lies wholly tip-side.
    """
    starts_tip = tip_side(_radius(points[0]))
    ends_tip = tip_side(_radius(points[-1]))
    if not starts_tip and not ends_tip:
        return None, None
    if starts_tip and ends_tip:
        return points, None
    kept = []
    previous = None
    for point in points:
        if tip_side(_radius(point)):
            if previous is not None and not tip_side(_radius(previous)):
                kept.append(_crossing(previous, point, form_radius))
            kept.append(point)
        previous = point
    if not kept:
        return None, None
    return kept, (kept[-1] if starts_tip else kept[0])


def one_pitch_edges(gear, spec, numpoints):
    """One space (internal) or one tooth (external), one angular pitch wide.

    FCGear returns three segments when its root circle is inside its base circle and five
    when the base circle is inside the root circle, and that follows the part rather than
    the spline kind.  In either shape one segment is a straight CHORD between the two flank
    ends and the gap to the next pitch is another chord; both are replaced by arcs at the
    same radius, so the tip and root diameters are true cylinders.

    When the table names a form diameter (T.I.F.), the involute stops there and a straight
    radial transition carries the flank out to the root circle, which is what that diameter
    means: past it there is no involute left for the mating part's tip to run on.

    Returns the edges of one pitch and the index of the arc on the root circle, which is
    where a round root is filleted.
    """
    segments = [[(float(p[0]), float(p[1])) for p in segment]
                for segment in gear.points(num=numpoints)]
    chord_index = {3: 1, 5: 2}.get(len(segments))
    if chord_index is None:
        raise RuntimeError(
            "FCGear returned %d segments for one tooth; expected 3 or 5" % len(segments))

    root_r = root_radius(spec)
    chord_at_root = abs(_radius(segments[chord_index][0]) - root_r) < 1e-6
    side_a = list(range(chord_index))
    side_b = list(range(chord_index + 1, len(segments)))
    # Each side ordered from the tooth tip toward the root, which is the direction the form
    # diameter cuts in; the walk order of the two sides then follows from that.
    if chord_at_root:
        orders = (side_a, list(reversed(side_b)))
    else:
        orders = (list(reversed(side_a)), side_b)
    transition_first = (not chord_at_root, chord_at_root)

    trimmed = list(segments)
    transitions = {}
    # A form diameter ends the involute where nothing else does.  A round root already ends
    # it with a fillet, so there the table's value is compared against the fillet rather than
    # forced onto it, and the transition below is skipped.
    if spec["form_diameter"] and spec["root_type"] == "flat":
        form_r = 0.5 * spec["form_diameter"]
        tip_side = ((lambda r: r <= form_r) if spec["kind"] == "internal"
                    else (lambda r: r >= form_r))
        radii = [_radius(p) for segment in segments for p in segment]
        if not min(radii) < form_r < max(radii):
            raise RuntimeError(
                "form_diameter %.6f does not lie between the tip and root radii (%.6f, %.6f)"
                % (spec["form_diameter"], 2.0 * min(radii), 2.0 * max(radii)))
        for order in orders:
            for position, index in enumerate(order):
                kept, crossing = _cut_at_radius(segments[index], form_r, tip_side)
                trimmed[index] = kept
                if crossing is None:
                    continue
                for later in order[position + 1:]:
                    trimmed[later] = None
                transitions[index] = (crossing, _on_circle(crossing, root_r))
                break

    sides = (side_a, side_b)
    built = ([], [])
    for part, indices in enumerate(sides):
        first = transition_first[part]
        for index in indices:
            crossing_root = transitions.get(index)
            if crossing_root and first:
                built[part].append(_line(crossing_root[1], crossing_root[0]))
            if trimmed[index]:
                built[part].append(_spline_edge(trimmed[index]))
            if crossing_root and not first:
                built[part].append(_line(crossing_root[0], crossing_root[1]))

    chord_radius = _radius(segments[chord_index][0])
    chord = _arc(built[0][-1].valueAt(built[0][-1].LastParameter),
                 built[1][0].valueAt(built[1][0].FirstParameter), chord_radius)
    edges = built[0] + [chord] + built[1]
    arc_radius = {len(built[0]): chord_radius}

    walk_start = edges[0].valueAt(edges[0].FirstParameter)
    walk_end = edges[-1].valueAt(edges[-1].LastParameter)
    closing_radius = _radius((walk_end.x, walk_end.y))
    if abs(_radius((walk_start.x, walk_start.y)) - closing_radius) > 1e-7:
        raise RuntimeError("the two ends of one pitch are not at the same radius")
    angle = math.atan2(walk_start.y, walk_start.x) + gear.phipart
    arc_radius[len(edges)] = closing_radius
    edges.append(_arc(walk_end, App.Vector(closing_radius * math.cos(angle),
                                           closing_radius * math.sin(angle), 0.0),
                      closing_radius))

    target = root_radius(spec)
    root_index = min(arc_radius, key=lambda index: abs(arc_radius[index] - target))
    if abs(arc_radius[root_index] - target) > 1e-6:
        raise RuntimeError(
            "neither arc of one pitch lands on the root diameter (%.6f vs %.6f)"
            % (2.0 * arc_radius[root_index], 2.0 * target))
    return edges, root_index


def profile_wire(gear, spec, numpoints):
    """The closed toothed profile, with a root fillet where the table asks for one.

    The whole boundary is assembled as one flat edge list first, because a root arc's two
    corners are not both inside its own pitch: when FCGear's chord is the arc at the tooth
    tip, the root arc is the closing arc and its far corner belongs to the next pitch.
    """
    pitch_edges, root_index = one_pitch_edges(gear, spec, numpoints)
    length = len(pitch_edges)
    pitch = Part.Wire(pitch_edges)
    copies = [pitch]
    for _ in range(spec["teeth"] - 1):
        rotation = App.Matrix()
        rotation.rotateZ(gear.phipart)
        copies.append(copies[-1].transformGeometry(rotation))
    flat = []
    for copy in copies:
        flat.extend(copy.Edges)

    # Rotating the flat list moves the seam off every root corner, so ordinary indexing
    # reaches both neighbours of each root arc instead of a wrap-around case.
    shift = (root_index + 2) % length
    if shift:
        flat = flat[shift:] + flat[:shift]
    total = len(flat)
    root_indices = sorted(((root_index + k * length - shift) % total
                           for k in range(spec["teeth"])), reverse=True)

    radius = spec["root_fillet_radius"]
    if radius > 0:
        from freecad.gears.basegear import insert_fillet

        for index in root_indices:
            try:
                before = len(flat)
                flat = insert_fillet(flat, index - 1, radius)
                flat = insert_fillet(flat, index + (len(flat) - before + 2) - 2, radius)
            except RuntimeError as exc:
                raise RuntimeError(
                    "a root fillet of radius %.6f does not fit on this tooth (%s). Reduce "
                    "root_fillet_radius, or use root_type: flat for sharp root corners."
                    % (radius, exc))
    return Part.Wire(flat)


def tooth_cutters(spec, tooth_centres):
    """Wedge cutters that delete the named teeth, leaving the rest of the ring whole."""
    z = spec["teeth"]
    alpha = spec["pressure_angle_deg"] * D2R
    rb = 0.5 * spec["pitch_diameter"] * math.cos(alpha)
    height = spec["face_width"]
    r_major = 0.5 * sc.mid(spec["major_diameter"])
    r_minor = 0.5 * sc.mid(spec["minor_diameter"])
    cutters = []
    for centre in tooth_centres:
        # The sector is cut at the widest radius the tooth reaches, so it swallows the
        # whole tooth; anything else it overlaps is a tooth space and therefore void.
        widest = r_major if spec["kind"] == "internal" else max(rb, r_minor)
        half = sm.tooth_angular_half_width(widest, z, alpha, rb, spec["kind"])
        if spec["kind"] == "internal":
            outer = r_major
            pts = [(0.0, 0.0)]
            steps = 96
            for i in range(steps + 1):
                a = centre - half + 2.0 * half * i / steps
                pts.append((outer * math.cos(a), outer * math.sin(a)))
            pts.append((0.0, 0.0))
        else:
            outer = r_major + 1.0
            steps = 96
            pts = []
            for i in range(steps + 1):
                a = centre - half + 2.0 * half * i / steps
                pts.append((r_minor * math.cos(a), r_minor * math.sin(a)))
            for i in range(steps, -1, -1):
                a = centre - half + 2.0 * half * i / steps
                pts.append((outer * math.cos(a), outer * math.sin(a)))
            pts.append(pts[0])
        wire = Part.makePolygon([App.Vector(x, y, -1.0) for x, y in pts])
        cutters.append(Part.Face(wire).extrude(App.Vector(0, 0, height + 2.0)))
    return cutters


# --------------------------------------------------------------------------- #
# Measurement                                                                  #
# --------------------------------------------------------------------------- #
def sample_wire(wire, per_mm=SAMPLE_PER_MM):
    """Points along a wire, in no particular order.

    A slice hands back edges in an order and direction that are not traversal order, so
    nothing downstream may depend on the sequence; the section analysis below sorts by
    polar angle instead.
    """
    points = []
    for edge in wire.Edges:
        count = max(16, int(edge.Length * per_mm))
        for i in range(count + 1):
            fraction = i / float(count)
            p = edge.valueAt(edge.FirstParameter + fraction * (edge.LastParameter - edge.FirstParameter))
            points.append((p.x, p.y))
    return points


def profile_wire_of(solid, spec, height):
    """The toothed section wire: the bore for an internal spline, the outline for an external one."""
    zc = 0.5 * height
    wires = []
    for section in solid.slice(App.Vector(0, 0, 1), zc):
        wires.extend(section.Wires)
    key = lambda w: max(_radius((v.Point.x, v.Point.y)) for v in w.Vertexes)  # noqa: E731
    return min(wires, key=key) if spec["kind"] == "internal" else max(wires, key=key)


def section_runs(solid, spec, points, r_ref, zc):
    """Where the mid-height section is material and where it is void at radius r_ref.

    Sorted by polar angle, the section is a single-valued radius profile (a spline is
    star-shaped about its axis), so a change of sign of ``radius - r_ref`` between
    consecutive angles is one crossing and the intervals between crossings alternate
    between material and void.  Sorting is what makes this independent of the edge order a
    slice returns, and one solid query then fixes every interval, which keeps the point
    test off the per-sample path.

    Returns the surviving tooth count and the void intervals whose width matches the
    table's own space width at r_ref.  A removed tooth merges two spaces into one interval,
    so width matching is also what keeps a measurement off the cut.
    """
    z = spec["teeth"]
    alpha = spec["pressure_angle_deg"] * D2R
    rb = 0.5 * spec["pitch_diameter"] * math.cos(alpha)
    expected = 2.0 * r_ref * sm.space_half_angle(r_ref, z, alpha, rb, spec["kind"])

    ordered = sorted(points, key=lambda p: math.atan2(p[1], p[0]))
    crossings = []
    for i in range(len(ordered)):
        x0, y0 = ordered[i]
        x1, y1 = ordered[(i + 1) % len(ordered)]
        r0 = math.hypot(x0, y0)
        r1 = math.hypot(x1, y1)
        if (r0 - r_ref) * (r1 - r_ref) <= 0 and r0 != r1:
            fraction = (r_ref - r0) / (r1 - r0)
            angle = math.atan2(y0 + fraction * (y1 - y0), x0 + fraction * (x1 - x0))
            if not crossings or abs(angle - crossings[-1]) > 1e-9:
                crossings.append(angle)
    crossings.sort()
    if len(crossings) < 4 or len(crossings) % 2:
        raise RuntimeError(
            "the section crosses r=%.6f at %d angles; expected an even count of at least 4"
            % (r_ref, len(crossings)))

    intervals = []
    for i in range(len(crossings)):
        a = crossings[i]
        b = crossings[(i + 1) % len(crossings)] + (2.0 * math.pi if i == len(crossings) - 1 else 0.0)
        intervals.append((a, b))
    first_mid = 0.5 * sum(intervals[0])
    first_is_material = solid.isInside(
        App.Vector(r_ref * math.cos(first_mid), r_ref * math.sin(first_mid), zc), 1e-6, True)

    teeth = 0
    spaces = []
    for index, (a, b) in enumerate(intervals):
        material = first_is_material if index % 2 == 0 else not first_is_material
        if material:
            teeth += 1
        elif abs((b - a) * r_ref - expected) <= 0.35 * expected:
            spaces.append(0.5 * (a + b))
    if not spaces:
        raise RuntimeError("no intact tooth space of the tabulated width at r=%.6f" % r_ref)
    return {"teeth": teeth,
            "space_angles": [angle % (2.0 * math.pi) for angle in spaces],
            "intervals": intervals,
            "expected_space_width": expected}


def measure(tag, solid, spec, build_info):
    z = spec["teeth"]
    alpha = spec["pressure_angle_deg"] * D2R
    module = spec["module"]
    d = spec["pitch_diameter"]
    rb = 0.5 * d * math.cos(alpha)
    height = spec["face_width"]
    zc = 0.5 * height

    wire = profile_wire_of(solid, spec, height)
    points = sample_wire(wire)
    radii = [math.hypot(x, y) for x, y in points]
    r_min, r_max = min(radii), max(radii)
    runs = section_runs(solid, spec, points, 0.5 * (r_min + r_max), zc)
    # The space nearest the +X axis is the reference one, so a measurement is reproducible
    # run to run rather than depending on which space the walk happened to find first.
    theta = min(runs["space_angles"], key=abs)

    ct, st = math.cos(-theta), math.sin(-theta)
    flank = []
    for x, y in points:
        xr, yr = x * ct - y * st, x * st + y * ct
        angle = math.atan2(yr, xr)
        if abs(angle) < 0.95 * math.pi / z:
            flank.append((math.hypot(xr, yr), abs(angle)))
    flank.sort()

    def half_angle_at(r):
        lo, hi = 0, len(flank) - 1
        if r <= flank[0][0]:
            return flank[0][1]
        if r >= flank[-1][0]:
            return flank[-1][1]
        while hi - lo > 1:
            k = (lo + hi) // 2
            if flank[k][0] < r:
                lo = k
            else:
                hi = k
        r0, t0 = flank[lo]
        r1, t1 = flank[hi]
        return t0 + (t1 - t0) * (r - r0) / (r1 - r0) if r1 > r0 else t0

    def space_at(r):
        th = half_angle_at(r)
        return 2.0 * r * th, 2.0 * r * math.sin(th)

    r_minor = 0.5 * sc.mid(spec["minor_diameter"])
    r_major = 0.5 * sc.mid(spec["major_diameter"])
    core = [(r, t) for r, t in flank if r_minor + 1e-6 < r < r_major - 1e-6]
    deviations = [abs(t - sm.space_half_angle(r, z, alpha, rb, spec["kind"])) for r, t in core]
    median_dev = sorted(deviations)[len(deviations) // 2]
    tolerance = max(1.0e-4, 6.0 * median_dev)

    # The form diameter is where the flank leaves the involute: walking in from the root
    # circle, which is the major diameter for an internal spline and the minor for an
    # external one, and so is the largest radius in the one case and the smallest in the
    # other.
    order = -1 if spec["kind"] == "internal" else 1
    form_r = None
    for (r, _), deviation in sorted(zip(core, deviations), key=lambda item: order * item[0][0]):
        if deviation <= tolerance:
            form_r = r
            break
    if form_r is None:
        form_r = r_max

    pin_radius = 0.5 * spec["pin_diameter"] if spec["pin_diameter"] else None
    pin_closed = None
    pin_residual = None
    if pin_radius:
        pin_closed = sm.pin_measurement(
            z, module, alpha, 0.5 * math.pi * module, spec["pin_diameter"], spec["kind"])
        selected = []
        for x, y in points:
            xr, yr = x * ct - y * st, x * st + y * ct
            if abs(math.atan2(yr, xr)) < 0.95 * math.pi / z:
                selected.append((xr, yr))
        pin_residual = min(math.hypot(x - pin_closed["Rc"], y) for x, y in selected)

    return {
        "minor_diameter": 2.0 * r_min,
        "major_diameter": 2.0 * r_max,
        "space_centreline_deg": math.degrees(theta) % 360.0,
        "space_width_at_pitch_arc": space_at(0.5 * d)[0],
        "space_width_at_pitch_chord": space_at(0.5 * d)[1],
        "space_width_basic": 0.5 * math.pi * module,
        "flank_vs_involute_median_dev_rad": median_dev,
        "flank_vs_involute_max_dev_rad": max(deviations),
        "involute_form_diameter": 2.0 * form_r,
        "pin_Rc_closed_form": pin_closed["Rc"] if pin_closed else None,
        "pin_dim": pin_closed["M"] if pin_closed else None,
        "pin_tangency_residual": pin_residual,
        "teeth_in_section": runs["teeth"],
        "volume_mm3": solid.Volume,
        "expected_volume_uncut_mm3": build_info["uncut_volume_mm3"],
        "module_used": module,
        "tag": tag,
    }


# --------------------------------------------------------------------------- #
# Comparison                                                                   #
# --------------------------------------------------------------------------- #
def row(item, table, computed, note=""):
    difference = None
    if table is not None and computed is not None:
        difference = computed - table
    return {"item": item, "table": table, "computed": computed,
            "difference": difference, "note": note}


def comparison(spec, measured):
    """Computed against tabulated values, item by item, as the summary must show."""
    z = spec["teeth"]
    alpha = spec["pressure_angle_deg"] * D2R
    module = spec["module"]
    pin_dia = spec["pin_diameter"]
    width = measured["space_width_at_pitch_arc"]
    rows = [
        row("major diameter (midpoint of the table's limits)",
            sc.mid(spec["major_diameter"]), measured["major_diameter"], "measured"),
        row("minor diameter (midpoint of the table's limits)",
            sc.mid(spec["minor_diameter"]), measured["minor_diameter"], "measured"),
        row("space width in force (basis: %s)" % spec["space_width_basis"],
            spec["space_width_target"], width, "measured, arc at the pitch circle"),
    ]
    if spec["form_diameter"]:
        rows.append(row("form diameter (T.I.F.)", spec["form_diameter"],
                        measured["involute_form_diameter"],
                        "measured; the involute is truncated there and a root transition runs "
                        "out to the root circle" if spec["root_type"] == "flat" else
                        "measured; a round root ends the involute with its fillet"))
    for key, value in sc.space_width_limits(spec):
        rows.append(row("space width %s" % key, value, width, "measured, arc"))
    if not pin_dia:
        return rows
    pin_at = lambda e: sm.pin_measurement(z, module, alpha, e, pin_dia, spec["kind"])["M"]  # noqa: E731
    for table_pin in spec["over_pins"]:
        rows.append(row("pin dimension (space width in force)", table_pin, measured["pin_dim"],
                        "computed" if spec["pin_dimension_basis"] == "computed"
                        else "the table's value is the one of record"))
    for key, value in sc.space_width_limits(spec):
        for table_pin in spec["over_pins"]:
            rows.append(row("pin dimension (space width = %s %g)" % (key, value),
                            table_pin, pin_at(value), "computed"))
    band = [sm.pin_measurement(z, module, alpha, e, pin_dia, spec["kind"])["M"]
            for e in [v for _, v in sc.space_width_limits(spec)] or [spec["space_width_target"]]]
    for table_pin in spec["over_pins"]:
        rows.append(row("pin dimension inside the band implied by the table's space widths",
                        table_pin, table_pin,
                        "band %.6f .. %.6f" % (min(band), max(band))))
    if spec["pin_dimension_basis"] == "drawing":
        rows.append(row("pin dimension of record", None, spec["over_pins"][0],
                        "the table's own value; it lists %s"
                        % ", ".join("%.6f" % v for v in spec["over_pins"])))
    else:
        rows.append(row("pin dimension of record", None, measured["pin_dim"],
                        "computed from the geometry in force"))
    return rows


def render_check(document):
    lines = ["# spline-to-step check summary",
             "",
             "FreeCAD %s.  'measured' is read off the built solid and 'computed' is the"
             % document["freecad_version"],
             "closed-form involute relation.  A pin dimension is compared at the table's own",
             "space width values, because a table's nominal space width already carries its",
             "tolerance band.",
             ""]
    for name, part in sorted(document["parts"].items()):
        spec = part["spec"]
        measured = part["measure"]
        lines.append("## %s  (%s, %d teeth, module %.6f, pressure angle %.4f deg, %s root)"
                     % (name, spec["kind"], spec["teeth"], spec["module"],
                        spec["pressure_angle_deg"], spec["root_type"]))
        lines.append("")
        for note in spec["notes"]:
            lines.append("- note: %s" % note)
        lines.append("")
        lines.append("| item | table | computed | difference | note |")
        lines.append("|---|---|---|---|---|")
        for entry in part["check"]:
            fmt = lambda v: "-" if v is None else "%.6f" % v  # noqa: E731
            lines.append("| %s | %s | %s | %s | %s |"
                         % (entry["item"], fmt(entry["table"]), fmt(entry["computed"]),
                            "-" if entry["difference"] is None else "%+.6f" % entry["difference"],
                            entry["note"] or ""))
        lines.append("")
        lines.append("| geometry | value |")
        lines.append("|---|---|")
        for key in ("minor_diameter", "major_diameter", "involute_form_diameter",
                    "space_width_at_pitch_arc", "space_width_at_pitch_chord",
                    "pin_dim", "pin_tangency_residual", "teeth_in_section",
                    "volume_mm3", "flank_vs_involute_median_dev_rad"):
            value = measured.get(key)
            if value is None:
                text = "-"
            elif key.endswith("_rad"):
                text = "%.3e" % value
            elif key == "teeth_in_section":
                text = "%d" % int(round(value))
            else:
                text = "%.6f" % value
            lines.append("| %s | %s |" % (key, text))
        if part.get("step_roundtrip"):
            lines.append("")
            lines.append("STEP round trip: re-imported volume %.3f mm3, minor %.6f, major %.6f"
                         % (part["step_roundtrip"]["volume_mm3"],
                            part["step_roundtrip"]["minor_diameter"],
                            part["step_roundtrip"]["major_diameter"]))
        lines.append("")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# Driver                                                                       #
# --------------------------------------------------------------------------- #
def build_one(spec, outdir, numpoints, verify):
    module = spec["module"]
    head_factor, clearance_factor = truncation_factors(spec, module)
    doc, source = gear_source(spec, module, head_factor, clearance_factor, numpoints)
    try:
        apply_space_width(spec, source, doc)
        gear = source.gear
        profile = profile_wire(gear, spec, numpoints)
        height = spec["face_width"]
        if spec["kind"] == "internal":
            solid = Part.makeCylinder(0.5 * spec["outer_diameter"], height).cut(
                Part.Face(profile).extrude(App.Vector(0, 0, height)))
        else:
            solid = Part.Face(profile).extrude(App.Vector(0, 0, height))
        if solid.Volume <= 0:
            raise RuntimeError("the boolean produced an empty solid")
        uncut_volume = solid.Volume

        removed = []
        if spec["missing_teeth"]:
            section = profile_wire_of(solid, spec, height)
            pts = sample_wire(section)
            radii = [math.hypot(x, y) for x, y in pts]
            runs = section_runs(solid, spec, pts, 0.5 * (min(radii) + max(radii)), 0.5 * height)
            space = min(runs["space_angles"], key=abs)
            # FCGear puts one space of the first pitch on +X, so the first tooth sits a half
            # pitch away - true of an internal space and of an external tooth alike.  Taking
            # the space nearest +X keeps the removed position the same on every run.
            first_tooth = space + math.pi / spec["teeth"]
            centres = [first_tooth + index * 2.0 * math.pi / spec["teeth"]
                       for index in range(spec["missing_teeth"])]
            for cutter in tooth_cutters(spec, centres):
                solid = solid.cut(cutter)
            removed = [math.degrees(c) % 360.0 for c in centres]
        doc.recompute()

        build_info = {
            "head_factor": head_factor,
            "clearance_factor": clearance_factor,
            "fillet_radius_mm": spec["root_fillet_radius"],
            "numpoints": numpoints,
            "uncut_volume_mm3": uncut_volume,
            "removed_tooth_centrelines_deg": removed,
        }
        measured = measure(spec["name"], solid, spec, build_info)
        measured["volume_removed_by_cut_mm3"] = uncut_volume - solid.Volume
        if abs(measured["space_width_at_pitch_arc"] - spec["space_width_target"]) > 1e-4:
            raise RuntimeError(
                "the built tooth space is %.6f mm wide at the pitch circle, the table's %s "
                "basis asks for %.6f"
                % (measured["space_width_at_pitch_arc"], spec["space_width_basis"],
                   spec["space_width_target"]))

        step_path = os.path.join(outdir, spec["name"] + ".step")
        # Shape.exportStep writes the shape's geometry.  Part.export() writes only the
        # product wrapper around a bare TopoShape, which yields a valid ISO-10303-21 file
        # with no shape in it, so the round trip below is what proves the file.
        solid.exportStep(step_path)
        with open(step_path, "r", encoding="utf-8", errors="replace") as handle:
            header = handle.readline().strip()
        if not header.startswith(STEP_HEADER):
            raise RuntimeError("%s does not start with %s (got %r)" % (step_path, STEP_HEADER, header))
        roundtrip = None
        if verify:
            reopened = Part.read(step_path)
            if reopened.isNull() or not reopened.Solids:
                raise RuntimeError("%s re-imported as an empty shape; no geometry was written"
                                   % step_path)
            if abs(reopened.Volume - solid.Volume) > 1e-6 * max(1.0, solid.Volume):
                raise RuntimeError("%s re-imported at volume %.6f, the built solid is %.6f"
                                   % (step_path, reopened.Volume, solid.Volume))
            section = profile_wire_of(reopened, spec, height)
            pts = sample_wire(section)
            radii = [math.hypot(x, y) for x, y in pts]
            roundtrip = {"volume_mm3": reopened.Volume,
                         "minor_diameter": 2.0 * min(radii),
                         "major_diameter": 2.0 * max(radii)}
        return {
            "spec": spec,
            "build": build_info,
            "measure": measured,
            "check": comparison(spec, measured),
            "step": os.path.basename(step_path),
            "step_header": header,
            "step_roundtrip": roundtrip,
        }
    finally:
        App.closeDocument(doc.Name)


def main(argv):
    parser = argparse.ArgumentParser(
        prog="gen_step.py",
        description="Build involute spline STEP models from parameter-table schemas.")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--numpoints", type=int, default=NUMPOINTS,
                        help="FCGear flank sample count (default %d)" % NUMPOINTS)
    parser.add_argument("--no-verify", action="store_true",
                        help="skip re-importing each exported STEP to confirm it")
    parser.add_argument("specs", nargs="+", help="parameter-table schema (.yaml or .json)")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.out):
        os.makedirs(args.out)

    document = {"freecad_version": ".".join(str(v) for v in App.Version()[:3]), "parts": {}}
    for path in args.specs:
        spec = sc.normalize(sc.load(path), path)
        print("=== %s : %s spline, %d teeth" % (spec["name"], spec["kind"], spec["teeth"]), flush=True)
        for note in spec["notes"]:
            print("    note: %s" % note, flush=True)
        part = build_one(spec, args.out, args.numpoints, not args.no_verify)
        document["parts"][spec["name"]] = part
        measured = part["measure"]
        print("    module=%.6f  minor=%.6f  major=%.6f  fillet=%.4f mm"
              % (measured["module_used"], measured["minor_diameter"],
                 measured["major_diameter"], part["build"]["fillet_radius_mm"]), flush=True)
        print("    space@PCD=%.6f  form=%.6f  pin=%s  teeth=%d"
              % (measured["space_width_at_pitch_arc"], measured["involute_form_diameter"],
                 "%.6f" % measured["pin_dim"] if measured["pin_dim"] else "-",
                 measured["teeth_in_section"]), flush=True)
        if part["step_roundtrip"]:
            print("    step round trip: volume %.3f mm3 (solid %.3f mm3)"
                  % (part["step_roundtrip"]["volume_mm3"], measured["volume_mm3"]), flush=True)
        print("    wrote %s" % os.path.join(args.out, part["step"]), flush=True)

    with open(os.path.join(args.out, "check.json"), "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    with open(os.path.join(args.out, "check.txt"), "w", encoding="utf-8") as handle:
        handle.write(render_check(document))
    print("wrote check.json and check.txt", flush=True)
    return 0


def _script_argv():
    """Our own arguments, whoever launched us.

    ``freecadcmd.exe`` execs the file it is given without setting ``__name__``, and it
    keeps its own argv, so the interpreter, this file's own path, and FreeCAD's
    ``--pass`` separator all have to come off before argparse sees them.
    """
    script = os.path.basename(__file__) if "__file__" in globals() else "gen_step.py"
    argv = []
    for token in sys.argv[1:]:
        if token == "--pass":
            continue
        if os.path.basename(token).lower() == script.lower():
            continue
        argv.append(token)
    return argv


def _launched_here():
    """True when this file is the program being run, not a module being imported."""
    if __name__ == "__main__":
        return True
    return any(os.path.basename(t).lower() == "gen_step.py" for t in sys.argv[1:])


# freecadcmd execs this file without setting __name__ to "__main__", so detect the run
# by the script path instead of relying on the usual guard.  It reports a failed script as
# a message and still exits 0, so a failure has to leave through sys.exit to reach the
# caller's exit status.
try:
    if _launched_here():
        sys.exit(main(_script_argv()))
except SystemExit:
    raise
except Exception:
    traceback.print_exc()
    sys.exit(1)
