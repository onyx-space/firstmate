#!/usr/bin/env bash
# run_freecad.sh - drive scripts/gen_step.py through a headless FreeCAD.
#
# Usage:
#   scripts/run_freecad.sh --out DIR [--no-verify] [--numpoints N] spec.yaml [spec2.yaml ...]
#
# Two situations, chosen automatically:
#
#   * FreeCAD runs on this operating system - Linux, macOS, or a Windows shell.  The
#     headless binary is invoked directly and every path is passed through unchanged.
#   * WSL drives the Windows-side FreeCAD.  The Windows interpreter cannot read a WSL
#     path, so the scripts and the specs are staged into the Windows temp directory,
#     the run happens there, and the artifacts are copied back into --out.
#
# The Windows interpreter is `freecadcmd.exe`.  From WSL it needs a WSLinterop handle,
# which this script exports when it is missing; without one it fails with "Invalid
# argument".
#
# Environment:
#   FREECADCMD    headless FreeCAD binary, when auto-detection does not find it
#   SPLINE_FREECAD_TIMEOUT  backstop seconds for one FreeCAD run (default 900)
#
# Exit status is FreeCAD's own, so a geometry failure is never reported as success.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TIMEOUT="${SPLINE_FREECAD_TIMEOUT:-900}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

out=""
extra=()
specs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:-}"; shift 2 ;;
    --out=*) out="${1#--out=}"; shift ;;
    --no-verify|--numpoints) extra+=("$1"); [ "$1" = "--numpoints" ] && { extra+=("${2:-}"); shift; }; shift ;;
    --numpoints=*) extra+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "run_freecad.sh: unknown option $1" >&2; exit 2 ;;
    *) specs+=("$1"); shift ;;
  esac
done

[ -n "$out" ] || { echo "run_freecad.sh: --out DIR is required" >&2; exit 2; }
[ "${#specs[@]}" -gt 0 ] || { echo "run_freecad.sh: at least one spec file is required" >&2; exit 2; }
for spec in "${specs[@]}"; do
  [ -f "$spec" ] || { echo "run_freecad.sh: no such spec: $spec" >&2; exit 2; }
done

mkdir -p "$out"
out="$(cd "$out" && pwd)"

find_windows_exe() {
  local candidate
  for candidate in ${FREECADCMD:-} /mnt/c/Users/*/AppData/Local/Programs/FreeCAD*/bin/freecadcmd.exe; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

native=""
for candidate in ${FREECADCMD:-} FreeCADCmd freecadcmd; do
  if command -v "$candidate" >/dev/null 2>&1; then native="$candidate"; break; fi
done

if [ -n "$native" ]; then
  exec "$native" "$HERE/gen_step.py" --pass --out "$out" ${extra[@]+"${extra[@]}"} "${specs[@]}"
fi

windows_exe="$(find_windows_exe)" || {
  echo "run_freecad.sh: no headless FreeCAD found." >&2
  echo "  Set FREECADCMD to the binary, or - from WSL - install the Windows-side FreeCAD" >&2
  echo "  so that /mnt/c/Users/*/AppData/Local/Programs/FreeCAD*/bin/freecadcmd.exe exists." >&2
  exit 127
}

# /mnt/c/Users/<user>/AppData/Local/Programs/FreeCAD .../bin/freecadcmd.exe
user_mnt="$(printf '%s' "$windows_exe" | sed -E 's#(/mnt/[a-zA-Z]/Users/[^/]+)/.*#\1#')"
case "$user_mnt" in
  /mnt/[a-zA-Z]/Users/*) ;;
  *) echo "run_freecad.sh: cannot derive the Windows temp directory from $windows_exe" >&2; exit 2 ;;
esac
stage_mnt="$user_mnt/AppData/Local/Temp/spline-to-step"

win() {
  printf '%s' "$1" | sed -E 's#^/mnt/([a-zA-Z])/#\U\1:\\#; s#/#\\#g'
}

export WSL_INTEROP="${WSL_INTEROP:-}"
if [ -z "$WSL_INTEROP" ]; then
  # The newest handle wins; freecadcmd.exe fails with "Invalid argument" without one.
  WSL_INTEROP="$(find /run/WSL -maxdepth 1 -name '*_interop' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)"
  export WSL_INTEROP
fi
if [ -z "${WSL_INTEROP:-}" ]; then
  echo "run_freecad.sh: no WSL interop handle in /run/WSL; cannot start a Windows process" >&2
  exit 1
fi

rm -rf "$stage_mnt"
mkdir -p "$stage_mnt/out"
cp "$HERE"/*.py "$stage_mnt/"
staged_specs=()
for spec in "${specs[@]}"; do
  cp "$spec" "$stage_mnt/"
  staged_specs+=("$(basename "$spec")")
done

( cd "$stage_mnt" && timeout "$TIMEOUT" "$windows_exe" "$(win "$stage_mnt/gen_step.py")" \
    --pass --out "$(win "$stage_mnt/out")" ${extra[@]+"${extra[@]}"} "${staged_specs[@]}" )
status=$?

for artifact in "$stage_mnt/out"/*; do
  [ -e "$artifact" ] || continue
  cp -f "$artifact" "$out/"
done
echo "run_freecad.sh: freecadcmd exit=$status; artifacts copied to $out"
exit "$status"
