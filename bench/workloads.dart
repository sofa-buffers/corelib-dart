import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

// The cross-language benchmark datasets (BENCH_SPEC). The literal values below
// must match every other port exactly so the encoded bytes — and therefore the
// message sizes used in the numbers — are identical.

/// Golden ratio constant used to fill the `u64 array (1000)` workload.
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
  e.beginSequence(7);
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
    8000000
  ]); // u32
  e.writeSignedArray(10, const [
    -100000,
    -200000,
    -300000,
    -400000,
    -500000,
    -600000,
    -700000,
    -800000
  ]); // i32
  e.writeFp64Array(11, const [3.14159265, 6.28318530, 9.42477795, 12.56637060]);
  e.beginSequence(12);
  e.writeUnsigned(1, 99);
  e.writeSigned(2, -7);
  e.endSequence();
}

void encodeU64Array(sofab.Encoder e, Int64List data) {
  e.writeUnsignedArray(0, data);
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

/// Encodes [build] once into a fresh buffer to measure its byte length.
int encodedSize(void Function(sofab.Encoder) build) {
  return sofab.Encoder.encodeToBytes(build).length;
}
