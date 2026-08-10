import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

// The cross-language benchmark datasets (BENCH_SPEC). The literal values below
// must match every other port exactly so the encoded bytes — and therefore the
// message sizes used in the numbers — are identical.

/// Golden ratio constant used to fill the `u64 array (1000)` and `blob 1MB`
/// workloads. BENCH_SPEC deliberately derives both from this one constant, so
/// there is a single magic number to keep in step across the ports.
const int _phi = 0x9E3779B97F4A7C15;

/// `u64 array (1000)`: src[i] = i * 0x9E3779B97F4A7C15 (wrapping u64 multiply).
Int64List buildU64Array() {
  final a = Int64List(1000);
  for (var i = 0; i < 1000; i++) {
    a[i] = i * _phi; // Dart int is 64-bit two's-complement and wraps.
  }
  return a;
}

/// The `typical` message (7 fields, ids 1..7; ~37 bytes) used by `bench`.
void encodeTypical(sofab.Encoder e) {
  e.writeUnsigned(1, 0xDEADBEEF);
  e.writeSigned(2, -12345);
  e.writeBool(3, true);
  e.writeFp32(4, 3.14159);
  e.writeString(5, 'sofab');
  e.writeUnsignedArray(6, const [10, 20, 30, 40]); // u16 values
  e.beginSequenceLazy(7);
  e.writeUnsigned(1, 99);
  e.writeSigned(2, -7);
  e.endSequence();
}

/// The `perf` message (12 fields, ids 1..12; exactly 170 bytes) used by `perf`.
void encodePerf(sofab.Encoder e) {
  e.writeUnsigned(1, 0xDEADBEEF);
  e.writeSigned(2, -12345);
  e.writeUnsigned(3, 0x0123456789ABCDEF);
  e.writeSigned(4, -5000000000000);
  e.writeBool(5, true);
  e.writeFp32(6, 3.14159);
  e.writeFp64(7, 2.718281828459045);
  e.writeString(8, 'perf-benchmark-message');
  e.writeUnsignedArray(9, const [
    1000000,
    2000000,
    3000000,
    4000000,
    5000000,
    6000000,
    7000000,
    8000000,
  ]); // u32
  e.writeSignedArray(10, const [
    -100000,
    -200000,
    -300000,
    -400000,
    -500000,
    -600000,
    -700000,
    -800000,
  ]); // i32
  e.writeFp64Array(11, const [3.14159265, 6.28318530, 9.42477795, 12.56637060]);
  e.beginSequenceLazy(12);
  e.writeUnsigned(1, 99);
  e.writeSigned(2, -7);
  e.endSequence();
}

void encodeU64Array(sofab.Encoder e, Int64List data) {
  e.writeUnsignedArray(0, data);
}

// ---- `blob 1MB` (BENCH_SPEC) ----------------------------------------------

/// Payload length of the `blob 1MB` message: exactly 1,000,000 bytes, so `MB/s`
/// reads directly against the `MB = 1e6` convention.
const int blobLen = 1000000;

/// Encoded size of the `blob 1MB` message — a 1-byte header `(1 << 3) | 2`, a
/// 4-byte `fixlen_word` `(1000000 << 3) | 3`, and the payload. Like the `perf`
/// message's 170, it is a cross-port parity check.
const int blobEncodedSize = blobLen + 5;

/// Buffer size for the streaming `blob 1MB` rows: a fixed 4096 on every port
/// rather than each port's own preference, so the rows stay comparable across
/// languages. It is also the chunk size the decode row is fed in.
/// `minOutputBuffer` does not enter into it — it is at most 20, so 4096 always
/// satisfies it.
const int blobChunk = 4096;

/// The `blob 1MB` payload: `b[i] = (i * 0x9E3779B97F4A7C15) & 0xFF`. Storing
/// into a [Uint8List] truncates to the low byte, which is exactly the mask.
Uint8List buildBlob() {
  final b = Uint8List(blobLen);
  for (var i = 0; i < blobLen; i++) {
    b[i] = i * _phi;
  }
  return b;
}

/// The `blob 1MB` message: one field, id 1, declared **without** `maxlen` —
/// the unbounded declaration is the point, since it is what makes the message
/// larger than any buffer a caller could pre-size from the schema.
void encodeBlob(sofab.Encoder e, Uint8List blob) => e.writeBlob(1, blob);

/// The flush sink of the streaming `blob 1MB` row. BENCH_SPEC is explicit that
/// it **consumes and discards**: accumulating the bytes would charge the
/// streaming row a copy the one-shot row never pays, and I/O is not
/// deterministic under Callgrind. Folding one byte per call is the minimum that
/// keeps the call from being optimised away.
class DiscardSink {
  int acc = 0;
  int flushes = 0;
  int bytes = 0;

  void add(Uint8List chunk) {
    flushes++;
    bytes += chunk.length;
    if (chunk.isNotEmpty) acc ^= chunk[0];
  }
}

// ---- `composite` (BENCH_SPEC) ---------------------------------------------

/// One cycle of the `composite` string field: 1-, 2-, 3- and 4-byte UTF-8. The
/// 4-byte sequence is a surrogate pair in Dart's UTF-16 `String`, so this also
/// drives the encoder's non-ASCII transcode path.
const String compositeText = 'aä€\u{1d11e}';

/// Encoded size of the `composite` message — the cross-port parity check, the
/// same role `perf`'s 170 plays.
const int compositeEncodedSize = 956;

/// The 64 wrapper-array elements, `"item-0"` .. `"item-63"`, and the 320-byte
/// string of field 2 — both built **once**, outside anything measured.
///
/// Building them per op would put Dart's string interpolation and `*` operator
/// in a figure that is meant to be the encoder: 64 fresh `String`s and a 320-
/// character concatenation per iteration cost several times the encoding they
/// feed, and would have made `encode: composite` a report on the Dart runtime's
/// allocator. Both are `final` at library scope, so they are constructed lazily
/// on first use and never again.
final List<String> compositeItems = List<String>.generate(
  64,
  (i) => 'item-$i',
  growable: false,
);
final String compositeString = compositeText * 32;

/// The `composite` message: every encoder path the three flat datasets miss.
///
/// * **id 1** — the suite's only **wrapper array** (MESSAGE_SPEC §5.1): one
///   field header per element, element id = array index, so ids 0–15 take a
///   one-byte header and 16–63 take two. Each element is closed with
///   [sofab.Encoder.endSequence] only at the wrapper level; the elements
///   themselves are plain `string` fields, which is what the wrapper form of a
///   `array<string>` looks like on the wire.
/// * **id 2** — 320 UTF-8 bytes covering all four sequence widths, so §6.4's
///   validator runs on a payload that is not ASCII.
/// * **id 3** — nesting at **depth 3**, so the lazy hold-back run grows past
///   the single level `typical` and `perf` reach.
/// * **id 4** — equal to its declared default, so the encoder must **not**
///   write it: opened lazily, closed with the field closer, gone from the wire.
///   This is the hold-back's discard path, which nothing else here exercises.
/// * **id 130** — the suite's only **two-byte field header**, `(130 << 3) | 0`.
void encodeComposite(sofab.Encoder e) {
  // id 1: wrapper array of 64 strings, "item-0" .. "item-63".
  e.beginSequenceLazy(1);
  for (var i = 0; i < 64; i++) {
    e.writeString(i, compositeItems[i]);
  }
  e.endSequence();

  // id 2: 32 repetitions of a 10-byte, four-width UTF-8 cycle.
  e.writeString(2, compositeString);

  // id 3: { 1: { 1: { 1: unsigned 7 } }, 2: signed -1 }
  e.beginSequenceLazy(3);
  e.beginSequenceLazy(1);
  e.beginSequenceLazy(1);
  e.writeUnsigned(1, 7);
  e.endSequence();
  e.endSequence();
  e.writeSigned(2, -1);
  e.endSequence();

  // id 4: all-default struct — opened and dropped, emitting nothing.
  e.beginSequenceLazy(4);
  e.endSequence();

  // id 130: the two-byte header.
  e.writeUnsigned(130, 0xDEADBEEF);
}

/// A no-op visitor that fully traverses a message (reads every field) with
/// minimal per-field work — the decode hot path for benchmarking.
class CountingVisitor extends sofab.MessageVisitor {
  int fields = 0;
  @override
  void onUnsigned(int id, int value) => fields++;
  @override
  void onSigned(int id, int value) => fields++;
  @override
  void onFp32(int id, double value) => fields++;
  @override
  void onFp64(int id, double value) => fields++;
  @override
  void onString(int id, String value) => fields++;
  @override
  void onBlob(int id, Uint8List value) => fields++;
  @override
  void onUnsignedArray(int id, Int64List values) => fields += values.length;
  @override
  void onSignedArray(int id, Int64List values) => fields += values.length;
  @override
  void onFp32Array(int id, Float32List values) => fields += values.length;
  @override
  void onFp64Array(int id, Float64List values) => fields += values.length;
  @override
  sofab.MessageVisitor? onSequenceStart(int id) => this;
}

/// The `decode: composite skip-all` sink — the path a router or filter runs in
/// production: walk the message, materialize nothing.
///
/// In this port that is stated outright rather than implied by empty callbacks:
/// [sofab.MessageVisitor.shouldRead] refuses every leaf at **header** time, so
/// the payload is jumped over and never materialized or UTF-8-validated
/// (CORELIB_PLAN §6.4), and [sofab.MessageVisitor.onSequenceStart] returns
/// `null`, which drops each sub-sequence whole. A visitor that merely overrode
/// nothing would still be *read*: this port's default `onStringBytes`
/// transcodes to a Dart `String`, which is exactly the work this row is meant
/// to leave out. Its distance from `decode: composite` is what not-decoding is
/// worth here.
class SkipAllVisitor extends sofab.MessageVisitor {
  int skipped = 0;

  @override
  bool shouldRead(int id, int type) {
    skipped++;
    return false;
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    skipped++;
    return null;
  }
}

/// Encodes [build] once into a fresh buffer to measure its byte length.
int encodedSize(void Function(sofab.Encoder) build) {
  return sofab.Encoder.encodeToBytes(build).length;
}
