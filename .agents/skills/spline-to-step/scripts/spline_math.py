"""Closed-form involute-spline relations, and the independent pin tangency solve.

Standard library only, so the same module runs under FreeCAD's bundled Python,
under any system python3, and in CI.

Conventions
-----------
* All lengths are mm and all angles are radians unless the name says ``_deg``.
* ``alpha`` is the pressure angle at the pitch circle.
* ``rb`` is the BASE radius; ``space_half_angle`` is undefined at ``r <= rb``,
  and every caller samples strictly above it.

One involute relation covers both spline kinds.  For a tooth feature whose half
angular width about its own centreline is measured at radius ``r``:

    tooth_half_angle(r) = inv(alpha) + pi/(2z) - inv(alpha_r),  alpha_r = acos(rb/r)

At the pitch circle ``alpha_r == alpha``, so the half angle there is exactly
``pi/(2z)`` - the basic (zero-backlash) position.  ``tooth_half_angle`` is the
half width of an EXTERNAL spline's TOOTH and of an INTERNAL spline's SPACE; the
two are the same curve, which is why one function serves both.  ``space_half_angle``
below names the space (the void a pin enters) for either kind.
"""

import math

__all__ = [
    "inv",
    "inv_inverse",
    "acos",
    "basic",
    "module_for_pitch_diameter",
    "tooth_half_angle",
    "space_half_angle",
    "tooth_angular_half_width",
    "space_width_at",
    "pin_measurement",
    "pin_flank_points",
    "pin_tangency_residual",
]

TINY = 1e-12


def inv(a):
    """Involute function inv(a) = tan(a) - a."""
    return math.tan(a) - a


def inv_inverse(y, lo=0.0, hi=1.5, iters=200):
    """Invert the involute function by bisection (it is strictly increasing)."""
    for _ in range(iters):
        mid = 0.5 * (lo + hi)
        if inv(mid) < y:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def acos(x):
    """acos clamped to [-1, 1] so rounding cannot raise on a tangent radius."""
    return math.acos(max(-1.0, min(1.0, x)))


def basic(z, m, alpha):
    """Basic (zero-backlash) dimensions of a spur involute spline.

    z: number of teeth, m: module, alpha: pressure angle [rad].
    d pitch diameter, db base diameter, p circular pitch, e circular space width
    at the pitch diameter (= half the circular pitch for zero backlash).
    """
    d = z * m
    return {
        "z": z,
        "m": m,
        "d": d,
        "rb": 0.5 * d * math.cos(alpha),
        "db": d * math.cos(alpha),
        "p": math.pi * m,
        "e": 0.5 * math.pi * m,
    }


def module_for_pitch_diameter(d, z):
    """FCGear is driven by module; a table that fixes P.C.D. is driven through this."""
    return d / float(z)


def tooth_half_angle(r, z, alpha, rb):
    """Half angular width of the involute feature at radius r."""
    return inv(alpha) + math.pi / (2.0 * z) - inv(acos(rb / r))


def space_half_angle(r, z, alpha, rb, kind):
    """Half angular width of the tooth SPACE at radius r, about the space centreline.

    internal: the space is the same involute as an external tooth, so it is
              ``tooth_half_angle`` directly and the space narrows as r grows.
    external: the space is what is left of the angular pitch beside the tooth, so
              it is ``pi/z - tooth_half_angle`` and it widens as r grows.
    """
    th = tooth_half_angle(r, z, alpha, rb)
    return th if kind == "internal" else math.pi / z - th


def space_width_at(r, z, alpha, rb, kind):
    """(arc width, chord width) of the tooth space at radius r."""
    th = space_half_angle(r, z, alpha, rb, kind)
    return 2.0 * r * th, 2.0 * r * math.sin(th)


def tooth_angular_half_width(r, z, alpha, rb, kind):
    """Half angular width of the TOOTH at radius r, about the tooth centreline.

    The involute feature is the space for an internal spline and the tooth for an
    external one, so the tooth is the feature for one kind and its complement of the
    angular pitch for the other.  Used to size a wedge that must swallow a whole tooth.
    """
    th = tooth_half_angle(r, z, alpha, rb)
    return th if kind == "external" else math.pi / z - th


def pin_measurement(z, m, alpha, space_width, pin_dia, kind):
    """Dimension over two pins from the closed-form involute pin relation.

    A pin of diameter ``pin_dia`` resting in two opposite tooth spaces touches
    both flanks of each space, so its centre lies on the space centreline at the
    radius ``Rc`` where the pin circle is tangent to the involute:

        inv(alpha_c) = inv(alpha) +/- space_width/d -/+ pin_dia/db
                       (+ - for internal, - + for external)

    The sign follows the space half angle: internal spaces narrow with radius and
    external spaces widen with it.  ``space_width`` is the CIRCULAR space width at
    the pitch circle, so a table tolerance band is entered by passing its own
    ACT/EFF value.

    The measured dimension differs by kind because the pins sit on opposite sides
    of the part's material:

        internal: the pins are inside the bore, and the drawing dimensions the gap
                  between the pins' facing surfaces,  M = 2*Rc - pin_dia
        external: the pins straddle the shaft, and the drawing dimensions across
                  the pins' outer surfaces,          M = 2*Rc + pin_dia
    """
    g = basic(z, m, alpha)
    d_p = float(pin_dia)
    if kind == "internal":
        inv_ac = inv(alpha) + space_width / g["d"] - d_p / g["db"]
    else:
        inv_ac = inv(alpha) - space_width / g["d"] + d_p / g["db"]
    alpha_c = inv_inverse(inv_ac)
    rc = g["rb"] / math.cos(alpha_c)
    m_dim = 2.0 * rc - d_p if kind == "internal" else 2.0 * rc + d_p
    return {"alpha_c": alpha_c, "Rc": rc, "M": m_dim, "M_centres": 2.0 * rc}


def pin_flank_points(z, alpha, rb, r_lo, r_hi, kind, samples=2001):
    """Sample one space flank analytically, with the space centreline along +X.

    The result is what a pin resting in that space has to be tangent to.  Radii at
    or below the base circle are skipped, because the involute does not exist there.
    """
    pts = []
    for i in range(samples):
        r = r_lo + (r_hi - r_lo) * i / float(samples - 1)
        if r <= rb * (1.0 + 1e-9):
            continue
        th = space_half_angle(r, z, alpha, rb, kind)
        if th <= TINY:
            continue
        pts.append((r * math.cos(th), r * math.sin(th)))
    if len(pts) < 5:
        raise ValueError("pin check: not enough flank points between r_lo and r_hi")
    return pts


def pin_tangency_residual(z, alpha, rb, Rc, kind, r_lo, r_hi, samples=2001):
    """Distance from the pin centre (Rc, 0) to the nearest point of the space flank.

    A pin of radius ``pin_radius`` centred at ``Rc`` touches the flank exactly when
    this equals ``pin_radius``.  The flank is resampled from ``space_half_angle``
    and shares no algebra with ``pin_measurement``, so evaluating the residual at
    the closed-form ``Rc`` is an independent check of that formula.
    """
    pts = pin_flank_points(z, alpha, rb, r_lo, r_hi, kind, samples)
    return min(math.hypot(x - Rc, y) for x, y in pts)
