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

# The `blob 1MB` rows move a megabyte per op, which is slow under Callgrind, so
# BENCH_SPEC lets them run at a much smaller pair: "R1 = 1, R2 = 3 is enough —
# the subtraction cancels fixed cost just as well at three reps as at three
# hundred."
BLOB_R1=1
BLOB_R2=3

# Encoded message sizes (must match perf's `message size`), by workload name.
declare -A SIZE
while read -r name bytes; do SIZE["$name"]="$bytes"; done < <(dart run bench/print_sizes.dart)

ir_for() { # workload reps -> total instruction count
  local workload="$1" reps="$2"
  local out
  out="$(valgrind --tool=callgrind --callgrind-out-file=/dev/null \
      "$BIN" "$workload" "$reps" 2>&1 1>/dev/null)"
  # Line looks like: ==12345== I   refs:      1,234,567
  echo "$out" | grep -E 'I +refs:' | head -n1 \
    | sed -E 's/.*I +refs: +//; s/,//g'
}

ir_per_op() { # workload [r1 r2] -> Ir/op (integer)
  local workload="$1" r1="${2:-$R1}" r2="${3:-$R2}"
  local i1 i2
  i1="$(ir_for "$workload" "$r1")"
  i2="$(ir_for "$workload" "$r2")"
  echo $(( (i2 - i1) / (r2 - r1) ))
}

echo "Measuring (this runs $((10 * 2)) Callgrind passes, please wait)..." >&2
ENC_U64="$(ir_per_op enc_u64)"
ENC_TYP="$(ir_per_op enc_typical)"
ENC_BLOB_1="$(ir_per_op enc_blob_oneshot "$BLOB_R1" "$BLOB_R2")"
ENC_BLOB_S="$(ir_per_op enc_blob_streaming "$BLOB_R1" "$BLOB_R2")"
ENC_COMP="$(ir_per_op enc_composite)"
DEC_U64="$(ir_per_op dec_u64)"
DEC_TYP="$(ir_per_op dec_typical)"
DEC_BLOB="$(ir_per_op dec_blob "$BLOB_R1" "$BLOB_R2")"
DEC_COMP="$(ir_per_op dec_composite)"
DEC_COMP_SKIP="$(ir_per_op dec_composite_skip)"

# Header, dashes and data rows all share one column layout (%-35s%8s%10s) so the
# instr/op and bytes columns line up exactly, matching BENCH_SPEC's table
# (instr/op column at col 35, bytes at col 48).
#
# `encode: blob 1MB passthrough` is BENCH_SPEC's one optional row and this port
# implements no pass-through (CORELIB_PLAN §5.1 makes it a MAY), so the row is
# omitted entirely rather than printed as a placeholder.
ROW='%-35s%8s%10s\n'
printf '===============================================================================\n'
printf ' SofaBuffers Dart instruction cost   (Callgrind, Ir/op)\n'
printf ' instructions/op: lower is better. Deterministic & machine-independent.\n'
printf '===============================================================================\n'
printf "$ROW" 'Workload' 'instr/op' 'bytes'
printf "$ROW" '--------' '--------' '-----'
printf "$ROW" 'encode: u64 array (1000)'   "$ENC_U64"       "${SIZE[u64]}"
printf "$ROW" 'encode: typical message'    "$ENC_TYP"       "${SIZE[typical]}"
printf "$ROW" 'encode: blob 1MB one-shot'  "$ENC_BLOB_1"    "${SIZE[blob]}"
printf "$ROW" 'encode: blob 1MB streaming' "$ENC_BLOB_S"    "${SIZE[blob]}"
printf "$ROW" 'encode: composite'          "$ENC_COMP"      "${SIZE[composite]}"
printf "$ROW" 'decode: u64 array (1000)'   "$DEC_U64"       "${SIZE[u64]}"
printf "$ROW" 'decode: typical message'    "$DEC_TYP"       "${SIZE[typical]}"
printf "$ROW" 'decode: blob 1MB'           "$DEC_BLOB"      "${SIZE[blob]}"
printf "$ROW" 'decode: composite'          "$DEC_COMP"      "${SIZE[composite]}"
printf "$ROW" 'decode: composite skip-all' "$DEC_COMP_SKIP" "${SIZE[composite]}"
