"""The parameter-table schema for spline-to-step: load, validate, normalise.

Standard library only.  Two input encodings are accepted:

* JSON (``.json``) - the full standard library parser.
* YAML (any other suffix) - a deliberately small YAML subset, because neither the
  system python3 nor FreeCAD's bundled interpreter is guaranteed to ship PyYAML.
  Supported: block mappings, nested blocks, block sequences, inline flow
  sequences ``[a, b]``, single/double quotes, ``#`` comments on their own line or
  after a value, blank lines, and ``null``/``~``.  Not supported: anchors, tags,
  multi-line scalars, multi-document streams, or nested flow collections.

Every field is validated here, so the generator that consumes this module can
assume types and never has to guess.  Nothing is defaulted silently: each default
the normaliser applies is appended to ``notes``, which the check summary prints.
"""

import json
import math
import re

__all__ = ["SchemaError", "load", "loads", "normalize", "mid", "space_width_limits"]

SPACE_WIDTH_KEYS = ("min_act", "max_act", "max_eff", "min_eff")
KINDS = ("internal", "external")
ROOT_TYPES = ("flat", "round")
SPACE_WIDTH_BASES = ("basic",) + SPACE_WIDTH_KEYS
PIN_DIMENSION_BASES = ("computed", "drawing")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# A drawing that gives only one of module / pitch diameter is unambiguous; a
# drawing that gives both and disagrees is driven by the pitch diameter (see the
# module docstring of normalize()).
DRIVE_CONFLICT_TOL_MM = 1e-6
DEFAULT_FACE_WIDTH_MM = 10.0
DEFAULT_RIM_FRACTION_OF_PCD = 0.15
ROUND_ROOT_FILLET_FRACTION_OF_MODULE = 0.35


class SchemaError(ValueError):
    """One deterministic schema failure, naming the field that is wrong."""


# --------------------------------------------------------------------------- #
# Loading                                                                      #
# --------------------------------------------------------------------------- #
def _strip_comment(line):
    out = []
    quote = None
    for ch in line:
        if quote is not None:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def _scalar(token):
    text = token.strip()
    if text == "" or text in ("~", "null", "Null", "NULL"):
        return None
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    low = text.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    return text


def _split_flow(body):
    items = []
    current = []
    quote = None
    for ch in body:
        if quote is not None:
            current.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            current.append(ch)
        elif ch == ",":
            items.append("".join(current))
            current = []
        else:
            current.append(ch)
    items.append("".join(current))
    return [_scalar(item) for item in items if item.strip() != ""]


def _value(token):
    text = token.strip()
    if text.startswith("[") and text.endswith("]"):
        return _split_flow(text[1:-1])
    if text.startswith("{") or text.startswith("&") or text.startswith("*") or text.startswith("|"):
        raise SchemaError(
            "unsupported YAML construct in %r; the schema accepts block maps, block "
            "sequences, inline [a, b] lists and scalars" % text
        )
    return _scalar(text)


def _block(lines, index, indent):
    if lines[index][1].startswith("- "):
        return _sequence(lines, index, indent)
    return _mapping(lines, index, indent)


def _sequence(lines, index, indent):
    items = []
    while index < len(lines) and lines[index][0] == indent and lines[index][1].startswith("- "):
        items.append(_value(lines[index][1][2:]))
        index += 1
    return items, index


def _mapping(lines, index, indent):
    result = {}
    while index < len(lines) and lines[index][0] == indent and not lines[index][1].startswith("- "):
        key, sep, rest = lines[index][1].partition(":")
        if not sep:
            raise SchemaError("expected 'key: value', got %r" % lines[index][1])
        key = key.strip()
        rest = rest.strip()
        index += 1
        if rest:
            result[key] = _value(rest)
        elif index < len(lines) and lines[index][0] > indent:
            result[key], index = _block(lines, index, lines[index][0])
        elif index < len(lines) and lines[index][0] == indent and lines[index][1].startswith("- "):
            result[key], index = _sequence(lines, index, indent)
        else:
            result[key] = None
    return result, index


def loads(text, source="<text>"):
    """Parse a YAML-subset or JSON document into plain Python data."""
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            data = json.loads(text)
        except ValueError as exc:
            raise SchemaError("%s: invalid JSON: %s" % (source, exc))
    else:
        lines = []
        for raw in text.splitlines():
            line = _strip_comment(raw)
            if not line.strip():
                continue
            lines.append((len(line) - len(line.lstrip(" ")), line.strip()))
        if not lines:
            raise SchemaError("%s: empty document" % source)
        data, index = _block(lines, 0, lines[0][0])
        if index != len(lines):
            raise SchemaError(
                "%s: unexpected indentation at %r" % (source, lines[index][1])
            )
    if not isinstance(data, dict):
        raise SchemaError("%s: the document must be a mapping of fields" % source)
    return data


def load(path):
    """Read one schema file, choosing the parser from the suffix."""
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if path.lower().endswith(".json"):
        try:
            data = json.loads(text)
        except ValueError as exc:
            raise SchemaError("%s: invalid JSON: %s" % (path, exc))
        if not isinstance(data, dict):
            raise SchemaError("%s: the document must be a mapping of fields" % path)
        return data
    return loads(text, path)


# --------------------------------------------------------------------------- #
# Validation                                                                   #
# --------------------------------------------------------------------------- #
def _require(raw, key, source):
    if key not in raw:
        raise SchemaError("%s: required field '%s' is missing" % (source, key))
    return raw[key]


def _number(raw, key, source, lo=None, hi=None):
    value = _require(raw, key, source)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SchemaError("%s: '%s' must be a number, got %r" % (source, key, value))
    value = float(value)
    if lo is not None and value <= lo:
        raise SchemaError("%s: '%s' must be greater than %s, got %r" % (source, key, lo, value))
    if hi is not None and value > hi:
        raise SchemaError("%s: '%s' must not exceed %s, got %r" % (source, key, hi, value))
    return value


def _integer(raw, key, source, lo=None):
    value = _require(raw, key, source)
    if isinstance(value, bool) or not isinstance(value, int):
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        else:
            raise SchemaError("%s: '%s' must be an integer, got %r" % (source, key, value))
    if lo is not None and value < lo:
        raise SchemaError("%s: '%s' must be at least %s, got %r" % (source, key, lo, value))
    return int(value)


def _pair(raw, key, source):
    """A diameter given either as one number or as a [min, max] limit pair."""
    value = _require(raw, key, source)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        value = float(value)
        return [value, value]
    if isinstance(value, list) and len(value) == 2:
        for item in value:
            if isinstance(item, bool) or not isinstance(item, (int, float)):
                raise SchemaError("%s: '%s' limits must be numbers, got %r" % (source, key, value))
        low, high = float(value[0]), float(value[1])
        if low <= 0 or high <= 0:
            raise SchemaError("%s: '%s' limits must be positive, got %r" % (source, key, value))
        return [min(low, high), max(low, high)]
    raise SchemaError(
        "%s: '%s' must be a number or a [limit, limit] pair, got %r" % (source, key, value)
    )


def _optional_number(raw, key, source):
    if raw.get(key) is None:
        return None
    return _number(raw, key, source, lo=0.0)


def _optional_list(raw, key, source, field="over_pins"):
    if raw.get(key) is None:
        return []
    value = raw[key]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return [float(value)]
    if isinstance(value, list) and value:
        out = []
        for item in value:
            if isinstance(item, bool) or not isinstance(item, (int, float)):
                raise SchemaError("%s: '%s' entries must be numbers, got %r" % (source, field, value))
            out.append(float(item))
        return out
    raise SchemaError("%s: '%s' must be a number or a list of numbers, got %r" % (source, field, value))


def _space_width(raw, source):
    value = raw.get("space_width")
    if value is None:
        return {key: None for key in SPACE_WIDTH_KEYS}
    if not isinstance(value, dict):
        raise SchemaError("%s: 'space_width' must be a mapping, got %r" % (source, value))
    unknown = sorted(set(value) - set(SPACE_WIDTH_KEYS))
    if unknown:
        raise SchemaError(
            "%s: 'space_width' has unknown keys %s; allowed keys are %s"
            % (source, ", ".join(unknown), ", ".join(SPACE_WIDTH_KEYS))
        )
    out = {}
    for key in SPACE_WIDTH_KEYS:
        item = value.get(key)
        if item is None:
            out[key] = None
        elif isinstance(item, bool) or not isinstance(item, (int, float)) or item <= 0:
            raise SchemaError("%s: 'space_width.%s' must be a positive number, got %r" % (source, key, item))
        else:
            out[key] = float(item)
    return out


def normalize(raw, source="<spec>"):
    """Validate one parameter table and resolve everything the generator needs.

    Drive rule: a table may state the module, the pitch diameter, or both.  When
    both are present and the module does not reproduce the stated pitch diameter,
    the pitch diameter drives the geometry (``m = pcd / z``) and the conflict is
    recorded in ``notes``.  A module is never silently preferred, because the
    pitch diameter is the dimension every other tabulated value is consistent
    with - a nominal module printed beside it is the rounded one.
    """
    if not isinstance(raw, dict):
        raise SchemaError("%s: the document must be a mapping of fields" % source)
    notes = []

    name = _require(raw, "name", source)
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise SchemaError(
            "%s: 'name' must be a file-safe identifier matching %s, got %r"
            % (source, NAME_RE.pattern, name)
        )

    kind = _require(raw, "kind", source)
    if kind not in KINDS:
        raise SchemaError("%s: 'kind' must be one of %s, got %r" % (source, "/".join(KINDS), kind))

    teeth = _integer(raw, "teeth", source, lo=3)
    pressure_angle_deg = _number(raw, "pressure_angle_deg", source, lo=0.0, hi=50.0)

    stated_module = float(raw["module"]) if raw.get("module") is not None else None
    stated_pcd = float(raw["pitch_diameter"]) if raw.get("pitch_diameter") is not None else None
    if stated_module is None and stated_pcd is None:
        raise SchemaError("%s: give 'module' or 'pitch_diameter'" % source)
    if stated_module is not None and stated_module <= 0:
        raise SchemaError("%s: 'module' must be positive, got %r" % (source, stated_module))
    if stated_pcd is not None and stated_pcd <= 0:
        raise SchemaError("%s: 'pitch_diameter' must be positive, got %r" % (source, stated_pcd))

    if stated_pcd is None:
        pitch_diameter = stated_module * teeth
        module = stated_module
    else:
        pitch_diameter = stated_pcd
        module = stated_pcd / float(teeth)
        if stated_module is not None:
            implied = stated_module * teeth
            if abs(implied - stated_pcd) > DRIVE_CONFLICT_TOL_MM:
                notes.append(
                    "drive conflict: module %g implies pitch diameter %.6f, the table states "
                    "%.6f; the pitch diameter drives the geometry and the module is treated as "
                    "nominal" % (stated_module, implied, stated_pcd)
                )
            else:
                notes.append(
                    "module %g and pitch diameter %.6f agree; both are consistent"
                    % (stated_module, stated_pcd)
                )

    root_type = _require(raw, "root_type", source)
    if root_type not in ROOT_TYPES:
        raise SchemaError(
            "%s: 'root_type' must be one of %s, got %r" % (source, "/".join(ROOT_TYPES), root_type)
        )
    root_fillet_radius = _optional_number(raw, "root_fillet_radius", source)
    if root_type == "flat":
        if root_fillet_radius:
            notes.append("root_type is 'flat'; the given root_fillet_radius is ignored")
        root_fillet_radius = 0.0
    elif root_fillet_radius is None:
        root_fillet_radius = ROUND_ROOT_FILLET_FRACTION_OF_MODULE * module
        notes.append(
            "round root with no radius on the table; using %.6f mm (0.35 * module), which is "
            "an assumption and not a standard value" % root_fillet_radius
        )
    if root_type == "round" and raw.get("form_diameter"):
        notes.append(
            "a round root ends the involute with its fillet, so form_diameter is compared "
            "against that fillet rather than truncating the flank; root_fillet_radius is what "
            "moves the measured form diameter"
        )

    major = _pair(raw, "major_diameter", source)
    minor = _pair(raw, "minor_diameter", source)
    if minor[0] >= major[1]:
        raise SchemaError(
            "%s: minor diameter %r must be smaller than major diameter %r" % (source, minor, major)
        )

    space_width = _space_width(raw, source)
    basis = raw.get("space_width_basis") or "basic"
    if basis not in SPACE_WIDTH_BASES:
        raise SchemaError(
            "%s: 'space_width_basis' must be one of %s, got %r"
            % (source, "/".join(SPACE_WIDTH_BASES), basis))
    if basis == "basic":
        space_width_target = 0.5 * math.pi * module
        notes.append(
            "space width basis is the basic (zero-backlash) value %.6f" % space_width_target)
    else:
        if not space_width[basis]:
            raise SchemaError(
                "%s: 'space_width_basis: %s' needs 'space_width.%s' on the table"
                % (source, basis, basis))
        space_width_target = space_width[basis]
        notes.append(
            "space width basis is %s = %.6f, so the geometry is built %+.6f mm wider than "
            "the basic value" % (basis, space_width_target,
                                 space_width_target - 0.5 * math.pi * module))
    limits = [value for _, value in space_width_limits({"space_width": space_width})]
    if limits:
        low, high = min(limits), max(limits)
        if not low - 1e-9 <= space_width_target <= high + 1e-9:
            notes.append(
                "the space width in force (%.6f) lies outside the table's own band %.6f .. "
                "%.6f" % (space_width_target, low, high))

    pin_diameter = _optional_number(raw, "pin_diameter", source)
    over_pins = _optional_list(raw, "over_pins", source)
    if over_pins and not pin_diameter:
        raise SchemaError("%s: 'over_pins' needs 'pin_diameter'" % source)
    pin_basis = raw.get("pin_dimension_basis") or "computed"
    if pin_basis not in PIN_DIMENSION_BASES:
        raise SchemaError(
            "%s: 'pin_dimension_basis' must be one of %s, got %r"
            % (source, "/".join(PIN_DIMENSION_BASES), pin_basis))
    if pin_basis == "drawing":
        if not over_pins:
            raise SchemaError(
                "%s: 'pin_dimension_basis: drawing' needs 'over_pins' on the table" % source)
        notes.append("pin dimension of record is the tabulated value(s) %s"
                     % ", ".join("%.6f" % value for value in over_pins))
    elif over_pins:
        notes.append("pin dimension of record is the computed value; the tabulated %s is "
                     "compared against it" % ", ".join("%.6f" % v for v in over_pins))

    missing_teeth = _integer(raw, "missing_teeth", source, lo=0) if raw.get("missing_teeth") is not None else 0
    if missing_teeth >= teeth - 2:
        raise SchemaError(
            "%s: 'missing_teeth' %d leaves fewer than three teeth of %d"
            % (source, missing_teeth, teeth)
        )
    if missing_teeth:
        notes.append(
            "missing_teeth=%d: removed consecutively from the tooth a half pitch beyond the "
            "tooth space nearest the +X axis, the same position on every run; the table "
            "carries no datum for it" % missing_teeth
        )

    face_width = _optional_number(raw, "face_width", source)
    if not face_width:
        face_width = DEFAULT_FACE_WIDTH_MM
        notes.append("no 'face_width' on the table; using %.3f mm" % face_width)

    outer_diameter = _optional_number(raw, "outer_diameter", source)
    if kind == "internal" and not outer_diameter:
        outer_diameter = mid(major) + 2.0 * DEFAULT_RIM_FRACTION_OF_PCD * pitch_diameter
        notes.append(
            "no 'outer_diameter' on the table; using %.6f mm (major diameter + 2 * 15%% of the "
            "pitch diameter). It sizes the rim only and does not touch the spline geometry"
            % outer_diameter
        )

    if root_type == "round" and root_fillet_radius >= 0.5 * (mid(major) - mid(minor)):
        raise SchemaError(
            "%s: root_fillet_radius %.6f does not fit the %.6f mm space between the minor and "
            "major diameters" % (source, root_fillet_radius, mid(major) - mid(minor))
        )

    return {
        "name": name,
        "kind": kind,
        "teeth": teeth,
        "module": module,
        "pitch_diameter": pitch_diameter,
        "module_stated": stated_module,
        "pressure_angle_deg": pressure_angle_deg,
        "root_type": root_type,
        "root_fillet_radius": root_fillet_radius,
        "major_diameter": major,
        "minor_diameter": minor,
        "form_diameter": _optional_number(raw, "form_diameter", source),
        "space_width": space_width,
        "space_width_basis": basis,
        "space_width_target": space_width_target,
        "pin_diameter": pin_diameter,
        "over_pins": over_pins,
        "pin_dimension_basis": pin_basis,
        "missing_teeth": missing_teeth,
        "face_width": face_width,
        "outer_diameter": outer_diameter,
        "standard": raw.get("standard"),
        "grade": raw.get("grade"),
        "notes": notes,
    }


def mid(pair):
    """Midpoint of a [min, max] limit pair; the nominal geometry a table implies."""
    return 0.5 * (pair[0] + pair[1])


def space_width_limits(spec):
    """The table's own space-width values, in schema order, as (label, value) pairs."""
    return [(key, spec["space_width"][key]) for key in SPACE_WIDTH_KEYS if spec["space_width"][key]]
