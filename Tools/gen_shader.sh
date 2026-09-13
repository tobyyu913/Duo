#!/bin/bash
#
# Embed the Duo Metal shader into the app as a Swift raw string.
#
#   Tools/gen_shader.sh            regenerate Sources/Duo/ShaderSource.swift
#
# Prefers Shaders/duo.metal (the real effect, designed separately); falls back to
# Shaders/passthrough.metal until it exists. The output is only rewritten when it
# actually changes so incremental `swift build`s stay fast.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/Sources/Duo/ShaderSource.swift"

if [[ -f "$HERE/Shaders/duo.metal" ]]; then
  SRC="$HERE/Shaders/duo.metal"
else
  SRC="$HERE/Shaders/passthrough.metal"
  echo "gen_shader: Shaders/duo.metal not found, embedding Shaders/passthrough.metal" >&2
fi

if grep -q '"""#' "$SRC"; then
  echo "gen_shader: $SRC contains the raw-string terminator '\"\"\"#'" >&2
  exit 1
fi

# Inside a #"""…"""# literal, '\#' is still the escape prefix (\#n → newline, \#( → interpolation,
# anything else → 'invalid escape sequence'). Refuse rather than silently alter the shader text.
if grep -q '\\#' "$SRC"; then
  echo "gen_shader: $SRC contains '\\#', the escape prefix inside a #\"\"\" raw string:" >&2
  grep -n '\\#' "$SRC" >&2
  exit 1
fi

TMP="$(mktemp)"
{
  echo "// GENERATED from Shaders/$(basename "$SRC") by Tools/gen_shader.sh — do not edit."
  echo 'let duoShaderSource = #"""'
  cat "$SRC"
  # Ensure the terminator starts on its own line even if the source lacks a final newline.
  [[ -n "$(tail -c1 "$SRC")" ]] && echo
  echo '"""#'
} > "$TMP"

if cmp -s "$TMP" "$OUT"; then
  rm -f "$TMP"
  echo "gen_shader: $(basename "$OUT") up to date ($(basename "$SRC"))"
else
  mv "$TMP" "$OUT"
  echo "gen_shader: wrote $(basename "$OUT") from $(basename "$SRC")"
fi
