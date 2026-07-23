import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// fp32 must round-trip **bit-for-bit** — including a signaling NaN, whose
/// "is-quiet" bit a 64-bit Dart `double` would set (CORELIB_PLAN §4.6: the
/// corelib never inspects or normalizes a float). Regression for the SofaBuffers
/// Crucible finding F-0031, where `0x7F800001` was quieted to `0x7FC00001`.

/// Captures the raw 32-bit pattern of every fp32 field, descending sequences.
class _BitVisitor extends sofab.MessageVisitor {
  final List<int> bits = <int>[];
  @override
  void onFp32Bits(int id, int b) => bits.add(b);
  @override
  sofab.MessageVisitor? onSequenceStart(int id) => this;
}

/// A consumer that only knows the legacy `double` API (must keep working).
class _DoubleVisitor extends sofab.MessageVisitor {
  final List<double> values = <double>[];
  @override
  void onFp32(int id, double v) => values.add(v);
}

/// Captures the fp32 array (a `Float32List`, whose storage holds raw bits).
class _ArrayVisitor extends sofab.MessageVisitor {
  Float32List? arr;
  @override
  void onFp32Array(int id, Float32List v) => arr = v;
}

int _reencodeBits(int bits) {
  final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Bits(1, bits));
  final v = _BitVisitor();
  expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
  return v.bits.single;
}

void main() {
  test('writeFp32Bits emits the four raw bytes verbatim (0x7F800001)', () {
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Bits(1, 0x7F800001));
    // header id1 fixlen (0x0a), fixlen_word (4<<3)|fp32 (0x20), 01 00 80 7f.
    expect(bytesToHex(wire), '0a200100807f');
  });

  test('signaling NaN 0x7F800001 survives decode → re-encode bit-for-bit', () {
    expect(_reencodeBits(0x7F800001), 0x7F800001);
  });

  test('assorted NaN payloads all round-trip bit-for-bit', () {
    for (final bits in const [
      0x7F800001, // fp32 signaling NaN (the F-0031 case)
      0x7FBFFFFF, // largest-payload signaling NaN
      0x7FC00001, // quiet NaN, same payload
      0xFFC00000, // negative quiet NaN
      0xFF800001, // negative signaling NaN
    ]) {
      expect(
        _reencodeBits(bits),
        bits,
        reason: '0x${bits.toRadixString(16)} must not be normalized',
      );
    }
  });

  test('streaming feed preserves the signaling NaN too (chunked, one byte at a time)', () {
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Bits(1, 0x7F800001));
    final v = _BitVisitor();
    final dec = sofab.Decoder(v);
    var status = sofab.DecodeStatus.complete;
    for (final b in wire) {
      status = dec.feed([b]);
    }
    expect(status, sofab.DecodeStatus.complete);
    expect(v.bits.single, 0x7F800001);
  });

  test('F-0031 reproduce message: nested.f32 = 0x7F800001 is preserved', () {
    // The exact wire from the issue: a sequence carrying an fp32 sNaN.
    final wire = hexToBytes('5602200100807f07a606560707c60c07ce0c07');
    final v = _BitVisitor();
    expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
    expect(v.bits, contains(0x7F800001));
  });

  test('a normal (finite) fp32 value is delivered as a double, not via bits', () {
    // Hot path unchanged: non-NaN values never route through onFp32Bits.
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32(1, 1.5));
    final bitV = _BitVisitor();
    final dblV = _DoubleVisitor();
    expect(sofab.Decoder.decode(wire, bitV), sofab.DecodeStatus.complete);
    expect(sofab.Decoder.decode(wire, dblV), sofab.DecodeStatus.complete);
    expect(bitV.bits, isEmpty);
    expect(dblV.values, [1.5]);
  });

  test('a legacy double-only consumer still receives the NaN (via the default bridge)', () {
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Bits(1, 0x7F800001));
    final v = _DoubleVisitor();
    expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
    expect(v.values.single.isNaN, isTrue);
  });

  // --- fp32 arrays: a Float32List carries raw 32-bit elements, so an array of
  // NaNs must round-trip bit-for-bit too (§4.6). -----------------------------

  Float32List f32ListOfBits(List<int> bits) {
    final arr = Float32List(bits.length);
    final asBits = arr.buffer.asUint32List(arr.offsetInBytes, bits.length);
    for (var i = 0; i < bits.length; i++) {
      asBits[i] = bits[i];
    }
    return arr;
  }

  List<int> bitsOf(Float32List arr) =>
      arr.buffer.asUint32List(arr.offsetInBytes, arr.length).toList();

  test('writeFp32Array emits Float32List element bytes verbatim (sNaN preserved)', () {
    final arr = f32ListOfBits([0x7F800001, 0x3F800000, 0xFF800001]);
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Array(1, arr));
    // header id1 array-fixlen (0x0d), count 3, word (4<<3)|fp32 (0x20), then
    // 3×4 LE bytes: 0100807f | 0000803f | 010080ff.
    expect(bytesToHex(wire), '0d0320' '0100807f' '0000803f' '010080ff');
  });

  test('fp32 array of NaNs round-trips bit-for-bit (contiguous decode)', () {
    final arr = f32ListOfBits([0x7F800001, 0x7FC00001, 0xFF800001, 0x7FBFFFFF]);
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Array(1, arr));
    final v = _ArrayVisitor();
    expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
    expect(bitsOf(v.arr!), bitsOf(arr));
    // And the delivered list re-encodes to the same bytes.
    final re = sofab.Encoder.encodeToBytes((e) => e.writeFp32Array(1, v.arr!));
    expect(bytesToHex(re), bytesToHex(wire));
  });

  test('fp32 array of NaNs is exact through the streaming path too (chunked)', () {
    final arr = f32ListOfBits([0x7F800001, 0xFF800001]);
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Array(1, arr));
    final v = _ArrayVisitor();
    final dec = sofab.Decoder(v);
    for (final b in wire) {
      dec.feed([b]);
    }
    expect(bitsOf(v.arr!), bitsOf(arr));
  });

  test('a plain List<double> fp32 array still encodes (no Float32List fast path)', () {
    // Non-Float32List input has no raw 32-bit storage; it goes through the
    // per-element path and must still produce correct bytes for finite values.
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeFp32Array(1, <double>[1.5, 2.0]));
    final v = _ArrayVisitor();
    expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
    expect(v.arr!.toList(), [1.5, 2.0]);
  });
}
