#!/usr/bin/env bash
set -euo pipefail

# This test compiles production URecord.pas and runs it with the production
# TAudioInputBase state machine and a fake device/backend. It requires a normal
# app Pascal-unit build (APP_UNIT_DIR) for UIni, UMusic, UCommon, etc. SDL is
# replaced only for mutex/tick calls; there is no real capture thread/device.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPC="${FPC:-fpc}"
APP_UNIT_DIR="${APP_UNIT_DIR:-$ROOT/../build/full_units}"
FPC_UNIT_ROOT="${FPC_UNIT_ROOT:-}"
# Optional, colon-separated link/runtime library directories for the app
# environment. Prefer these to ldconfig's host-library results so tests can
# use the same FFmpeg/SDL runtime that the selected app build uses.
APP_LIBRARY_DIRS="${APP_LIBRARY_DIRS:-}"
if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ultrastar-capture-state.XXXXXX")"
fi
APP_UNIT_DIR="$(cd "$APP_UNIT_DIR" && pwd)"
if [[ -n "$FPC_UNIT_ROOT" ]]; then
  FPC_UNIT_ROOT="$(cd "$FPC_UNIT_ROOT" && pwd)"
fi
BUILD_DIR="$(mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" && pwd)"
UNIT_DIR="$BUILD_DIR/units"
BIN_DIR="$BUILD_DIR/bin"
SHIM_DIR="$BUILD_DIR/shims"
ALIAS_DIR="$BUILD_DIR/aliases"

if [[ ! -f "$APP_UNIT_DIR/UIni.ppu" || ! -f "$APP_UNIT_DIR/UMusic.ppu" ]]; then
  echo "Missing app Pascal units at APP_UNIT_DIR=$APP_UNIT_DIR; build the app units first or set APP_UNIT_DIR." >&2
  exit 2
fi
mkdir -p "$UNIT_DIR" "$BIN_DIR" "$SHIM_DIR" "$ALIAS_DIR"

APP_LIBRARY_PATHS=()
if [[ -n "$APP_LIBRARY_DIRS" ]]; then
  IFS=: read -r -a APP_LIBRARY_PATHS <<< "$APP_LIBRARY_DIRS"
fi

cc -shared -fPIC "$ROOT/tests/stubs/sdl2_test_shim.c" -o "$SHIM_DIR/libSDL2.so"
cc -shared -fPIC "$ROOT/tests/stubs/empty_dependency_shim.c" -o "$SHIM_DIR/libSDL2_image.so"
cc -shared -fPIC "$ROOT/tests/stubs/empty_dependency_shim.c" -o "$SHIM_DIR/liblua5.3.so"

# Case-sensitive FPC unit lookup does not match the repository's mixed-case PPU.
if [[ -f "$APP_UNIT_DIR/SDL2_image.ppu" ]]; then
  ln -sf "$APP_UNIT_DIR/SDL2_image.ppu" "$ALIAS_DIR/sdl2_image.ppu"
  [[ ! -f "$APP_UNIT_DIR/SDL2_image.o" ]] || ln -sf "$APP_UNIT_DIR/SDL2_image.o" "$ALIAS_DIR/sdl2_image.o"
fi
if [[ -f "$APP_UNIT_DIR/UDLLManager.ppu" ]]; then
  ln -sf "$APP_UNIT_DIR/UDLLManager.ppu" "$ALIAS_DIR/UDllManager.ppu"
  [[ ! -f "$APP_UNIT_DIR/UDLLManager.o" ]] || ln -sf "$APP_UNIT_DIR/UDLLManager.o" "$ALIAS_DIR/UDllManager.o"
fi
if [[ -f "$APP_UNIT_DIR/freetype.ppu" ]]; then
  ln -sf "$APP_UNIT_DIR/freetype.ppu" "$ALIAS_DIR/FreeType.ppu"
  [[ ! -f "$APP_UNIT_DIR/freetype.o" ]] || ln -sf "$APP_UNIT_DIR/freetype.o" "$ALIAS_DIR/FreeType.o"
fi

FPC_FLAGS=(-Si -Sg -Sc)
FPC_UNIT_FLAGS=()
if [[ -n "$FPC_UNIT_ROOT" ]]; then
  # The extracted, user-local Debian FPC toolchain has no installed fpc.cfg.
  FPC_FLAGS=(-n -Si -Sg -Sc)
  FPC_EXEC_DIR="${FPC_EXEC_DIR:-$(dirname "$(dirname "$FPC_UNIT_ROOT")")}"
  export PATH="$FPC_EXEC_DIR:$PATH"
  while IFS= read -r dir; do FPC_UNIT_FLAGS+=("-Fu$dir"); done \
    < <(find "$FPC_UNIT_ROOT" -type d -print)
fi

# Use real system runtime libraries only as link dependencies; the SDL core
# shim is first so all capture/state tests remain explicitly synthetic.
link_runtime() {
  local output="$1" soname="$2" path="" dir
  for dir in "${APP_LIBRARY_PATHS[@]}"; do
    if [[ -e "$dir/$output" ]]; then
      path="$dir/$output"
      break
    fi
  done
  if [[ -z "$path" ]]; then
    path="$(ldconfig -p | awk -v n="$soname" '$1 == n { print $NF; exit }')"
  fi
  if [[ -z "$path" ]]; then
    echo "Missing link-time runtime library $soname (needed for the app-unit link)." >&2
    exit 2
  fi
  ln -sf "$path" "$SHIM_DIR/$output"
  echo "Link runtime $output -> $(readlink -f "$path")"
}
link_runtime libX11.so libX11.so.6
link_runtime libavcodec.so libavcodec.so.61
link_runtime libavformat.so libavformat.so.61
link_runtime libavutil.so libavutil.so.59
link_runtime libswscale.so libswscale.so.8
link_runtime libswresample.so libswresample.so.5
link_runtime libsqlite3.so libsqlite3.so.0
link_runtime libfreetype.so libfreetype.so.6

cd "$ROOT"
"$FPC" "${FPC_FLAGS[@]}" -B -Cn \
  -Fu"$APP_UNIT_DIR" -Fu"$ALIAS_DIR" \
  "${FPC_UNIT_FLAGS[@]}" \
  -Fi"$ROOT/src" -FU"$UNIT_DIR" \
  "$ROOT/src/base/URecord.pas"

"$FPC" "${FPC_FLAGS[@]}" \
  -Fu"$UNIT_DIR" -Fu"$APP_UNIT_DIR" -Fu"$ALIAS_DIR" \
  "${FPC_UNIT_FLAGS[@]}" \
  -Fi"$ROOT/src" -Fl"$SHIM_DIR" \
  -k--unresolved-symbols=ignore-all \
  -FU"$UNIT_DIR" -FE"$BIN_DIR" \
  "$ROOT/tests/record_capture_state_test.pas"

echo "Test artifacts: $BUILD_DIR"
LD_LIBRARY_PATH="$SHIM_DIR${APP_LIBRARY_DIRS:+:$APP_LIBRARY_DIRS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$BIN_DIR/record_capture_state_test"
