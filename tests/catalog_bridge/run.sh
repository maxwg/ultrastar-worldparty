#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${CATALOG_TEST_PYTHON:?Set CATALOG_TEST_PYTHON to an absolute existing Python executable.}"
: "${FPC_UNIT_ROOT:?Set FPC_UNIT_ROOT to the installed FPC units root.}"
FPC="${FPC:-fpc}"
case "$CATALOG_TEST_PYTHON" in /*) ;; *) echo "CATALOG_TEST_PYTHON must be absolute" >&2; exit 2 ;; esac
case "$FPC_UNIT_ROOT" in /*) ;; *) echo "FPC_UNIT_ROOT must be absolute" >&2; exit 2 ;; esac
[[ -x "$CATALOG_TEST_PYTHON" ]] || { echo "Python executable is missing" >&2; exit 2; }
[[ -d "$FPC_UNIT_ROOT" ]] || { echo "FPC unit root is missing" >&2; exit 2; }
BUILD_DIR="${BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/ultrastar-catalog-bridge.XXXXXX")}"
mkdir -p "$BUILD_DIR/units" "$BUILD_DIR/bin"
FPC_FLAGS=(-B)
FPC_UNIT_FLAGS=()
while IFS= read -r dir; do FPC_UNIT_FLAGS+=("-Fu$dir"); done < <(find "$FPC_UNIT_ROOT" -type d -print)
"$FPC" "${FPC_FLAGS[@]}" -Cn "${FPC_UNIT_FLAGS[@]}" -FU"$BUILD_DIR/units" "$ROOT/src/base/USongCatalogBridge.pas"
"$FPC" "${FPC_FLAGS[@]}" "${FPC_UNIT_FLAGS[@]}" -Fu"$BUILD_DIR/units" -FU"$BUILD_DIR/units" -FE"$BUILD_DIR/bin" "$ROOT/tests/catalog_bridge/catalog_bridge_test.pas"
"$BUILD_DIR/bin/catalog_bridge_test" "$CATALOG_TEST_PYTHON" "$ROOT/tests/catalog_bridge/inert_child.py" "$ROOT/tools/song_catalog.py" "$ROOT/tests/catalog_bridge/nonreader_child.py" "$ROOT/tests/catalog_bridge/closed_stdin_child.py"
"$FPC" "${FPC_FLAGS[@]}" "${FPC_UNIT_FLAGS[@]}" -Fu"$ROOT/src/base" -FU"$BUILD_DIR/units" -FE"$BUILD_DIR/bin" "$ROOT/tests/catalog_bridge/catalog_ui_helpers_test.pas"
"$BUILD_DIR/bin/catalog_ui_helpers_test"
"$FPC" "${FPC_FLAGS[@]}" "${FPC_UNIT_FLAGS[@]}" -Fu"$ROOT/src/base" -FU"$BUILD_DIR/units" -FE"$BUILD_DIR/bin" "$ROOT/tests/catalog_bridge/catalog_selection_test.pas"
"$BUILD_DIR/bin/catalog_selection_test"
"$FPC" "${FPC_FLAGS[@]}" "${FPC_UNIT_FLAGS[@]}" -Fu"$BUILD_DIR/units" -FU"$BUILD_DIR/units" -FE"$BUILD_DIR/bin" "$ROOT/tests/catalog_bridge/catalog_pipe_error_expression_test.pas"
"$BUILD_DIR/bin/catalog_pipe_error_expression_test"
"$CATALOG_TEST_PYTHON" "$ROOT/tests/catalog_bridge/check_windows_paths.py"
echo "Test artifacts: $BUILD_DIR"
