#!/usr/bin/env bash
# Instruction-cost tool (BENCH_SPEC): instructions retired per op (Callgrind
# Ir/op) — deterministic and machine-independent, available on every target.
#
# Dart is a JIT/AOT language with no stable per-workload native symbol to toggle,
# so this uses the **two-rep subtraction** method (BENCH_SPEC): each workload is
# run at two rep counts R1 < R2 under Callgrind and the instruction totals are
# subtracted:  Ir/op = (Ir(R2) - Ir(R1)) / (R2 - R1).  The subtraction cancels
# process startup, AOT loading and one-time setup, leaving the per-op cost.
#
# Usage:  bench/run_callgrind.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if ! command -v valgrind >/dev/null 2>&1; then
  echo "error: valgrind not found (install it: apt-get install valgrind)" >&2
  exit 1
fi

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"
BIN="$BUILD_DIR/callgrind_target"

echo "Compiling AOT target..." >&2
dart compile exe bench/callgrind_target.dart -o "$BIN" >/dev/null

# Rep counts. R2-R1 ops determine the per-op figure; keep R1 small so setup is
# cancelled but the run stays fast under Callgrind.
R1=200
R2=1000

# Encoded message sizes (must match perf's `message size`).
read -r SIZE_U64 SIZE_TYPICAL < <(dart run bench/print_sizes.dart)

ir_for() { # workload reps -> total instruction count
  local workload="$1" reps="$2"
  local out
  out="$(valgrind --tool=callgrind --callgrind-out-file=/dev/null \
      "$BIN" "$workload" "$reps" 2>&1 1>/dev/null)"
  # Line looks like: ==12345== I   refs:      1,234,567
  echo "$out" | grep -E 'I +refs:' | head -n1 \
    | sed -E 's/.*I +refs: +//; s/,//g'
}

ir_per_op() { # workload -> Ir/op (integer)
  local workload="$1"
  local i1 i2
  i1="$(ir_for "$workload" "$R1")"
  i2="$(ir_for "$workload" "$R2")"
  echo $(( (i2 - i1) / (R2 - R1) ))
}

echo "Measuring (this runs $((4 * 2)) Callgrind passes, please wait)..." >&2
ENC_U64="$(ir_per_op enc_u64)"
ENC_TYP="$(ir_per_op enc_typical)"
DEC_U64="$(ir_per_op dec_u64)"
DEC_TYP="$(ir_per_op dec_typical)"

printf '===============================================================================\n'
printf ' SofaBuffers Dart instruction cost   (Callgrind, Ir/op)\n'
printf ' instructions/op: lower is better. Deterministic & machine-independent.\n'
printf '===============================================================================\n'
printf 'Workload                           instr/op     bytes\n'
printf -- '--------                           --------     -----\n'
printf 'encode: u64 array (1000)      %12s  %8s\n' "$ENC_U64" "$SIZE_U64"
printf 'encode: typical message      %12s  %8s\n' "$ENC_TYP" "$SIZE_TYPICAL"
printf 'decode: u64 array (1000)      %12s  %8s\n' "$DEC_U64" "$SIZE_U64"
printf 'decode: typical message      %12s  %8s\n' "$DEC_TYP" "$SIZE_TYPICAL"
