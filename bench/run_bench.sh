#!/usr/bin/env bash
# Runs the throughput (`bench`) and per-op (`perf`) tools as **AOT-native**
# executables (`dart compile exe`) rather than on the JIT VM (`dart run`).
#
# AOT is the representative way to measure this library: it removes JIT warmup
# and is the fair comparison to the compiled ports (C/C++/Rust/Go), which also
# run native. For a quick JIT check, `dart run bench/bench.dart` still works.
#
# Usage:  bench/run_bench.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

echo "Compiling AOT executables..." >&2
dart compile exe bench/bench.dart -o "$BUILD_DIR/bench" >/dev/null
dart compile exe bench/perf.dart  -o "$BUILD_DIR/perf"  >/dev/null

"$BUILD_DIR/bench"
echo
"$BUILD_DIR/perf"
