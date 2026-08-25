import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// Varint edge cases across **both** decode surfaces.
///
/// The encoder builds varints a 64-bit word at a time and the one-shot decoder
/// reads them the same way, so the byte-length boundaries (1/2/3..8/9/10) and
/// the §4.1 tolerance rules are worth pinning down explicitly rather than
/// leaving them to whichever lengths the shared vectors happen to contain.
class _Collect extends sofab.MessageVisitor {
  final values = <int>[];
  final arrays = <List<int>>[];

  @override
  void onUnsigned(int id, int value) => values.add(value);
  @override
  void onSigned(int id, int value) => values.add(value);
  @override
  void onUnsignedArray(int id, Int64List v) => arrays.add(v.toList());
  @override
  void onSignedArray(int id, Int64List v) => arrays.add(v.toList());

  final events = <String>[];
  @override
  void onString(int id, String value) => events.add('STR:$id:$value');
  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    events.add('SEQ:$id');
    return this;
  }

  @override
  void onSequenceEnd() => events.add('END');
}

/// Decodes [bytes] one-shot **and** byte-at-a-time, asserting both surfaces
/// agree on the status and on everything they delivered.
_Collect _decodeBothWays(List<int> bytes, sofab.DecodeStatus expected) {
  final buf = Uint8List.fromList(bytes);

  final oneShot = _Collect();
  expect(
    sofab.Decoder.decode(buf, oneShot),
    expected,
    reason: 'one-shot (contiguous) decode',
  );

  final streamed = _Collect();
  final dec = sofab.Decoder(streamed);
  var status = sofab.DecodeStatus.complete;
  for (final b in buf) {
    status = dec.feed(Uint8List.fromList([b]));
  }
  expect(status, expected, reason: 'streaming decode, one byte per feed');

  expect(streamed.values, oneShot.values, reason: 'scalars must agree');
  expect(streamed.arrays, oneShot.arrays, reason: 'arrays must agree');
  expect(streamed.events, oneShot.events, reason: 'events must agree');
  return oneShot;
}

/// Every varint byte-length boundary, plus both 64-bit extremes.
const _boundaryValues = <int>[
  0, 1, 127, // 1 byte
  128, 16383, // 2
  16384, 2097151, // 3
  2097152, 268435455, // 4
  268435456, 34359738367, // 5
  34359738368, 4398046511103, // 6
  4398046511104, 562949953421311, // 7
  562949953421312, 72057594037927935, // 8
  72057594037927936, 0x7FFFFFFFFFFFFFFF, // 9
  -1, -9223372036854775808, // 10 (bit 63 set)
];

void main() {
  group('varint length boundaries', () {
    test('scalars round-trip at every byte length', () {
      for (final v in _boundaryValues) {
        final bytes = sofab.Encoder.encodeToBytes((e) => e.writeUnsigned(0, v));
        final got = _decodeBothWays(bytes, sofab.DecodeStatus.complete);
        expect(got.values, [v], reason: 'unsigned $v');
      }
    });

    test('array elements round-trip at every byte length', () {
      // One array carrying all of them exercises the word-wise element loop
      // *and* its near-end-of-buffer tail.
      final bytes = sofab.Encoder.encodeToBytes(
        (e) => e.writeUnsignedArray(1, Int64List.fromList(_boundaryValues)),
      );
      final got = _decodeBothWays(bytes, sofab.DecodeStatus.complete);
      expect(got.arrays, [_boundaryValues]);
    });

    test('signed (zig-zag) array elements round-trip', () {
      final signed = <int>[
        0,
        -1,
        1,
        -64,
        63,
        -8192,
        8191,
        -9223372036854775808,
        0x7FFFFFFFFFFFFFFF,
      ];
      final bytes = sofab.Encoder.encodeToBytes(
        (e) => e.writeSignedArray(1, Int64List.fromList(signed)),
      );
      final got = _decodeBothWays(bytes, sofab.DecodeStatus.complete);
      expect(got.arrays, [signed]);
    });

    test(
      'an array split across the word/tail boundary decodes identically',
      () {
        // Vary the element count so the point where the reader stops being able
        // to load a full 8-byte word lands on a different element each time.
        for (var n = 1; n <= 24; n++) {
          final vals = List<int>.generate(n, (i) => i * 0x9E3779B97F4A7C15);
          final bytes = sofab.Encoder.encodeToBytes(
            (e) => e.writeUnsignedArray(1, Int64List.fromList(vals)),
          );
          final got = _decodeBothWays(bytes, sofab.DecodeStatus.complete);
          expect(got.arrays, [vals], reason: 'count $n');
        }
      },
    );
  });

  group('non-minimal varints are accepted (CORELIB_PLAN §4.1)', () {
    // "A decoder MUST accept a non-minimal varint that stays within the 64-bit
    // bound, and decode it to the value it denotes."
    test('two-byte encoding of 5', () {
      final got = _decodeBothWays([
        0x00,
        0x85,
        0x00,
      ], sofab.DecodeStatus.complete);
      expect(got.values, [5]);
    });

    test('full-length (10-byte) encoding of 0', () {
      final got = _decodeBothWays([
        0x00,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x00,
      ], sofab.DecodeStatus.complete);
      expect(got.values, [0]);
    });

    test('re-encoding normalizes to the minimal form', () {
      final got = _decodeBothWays([
        0x00,
        0x85,
        0x00,
      ], sofab.DecodeStatus.complete);
      final re = sofab.Encoder.encodeToBytes(
        (e) => e.writeUnsigned(0, got.values.single),
      );
      expect(re, [0x00, 0x05]);
    });

    test('non-minimal array elements', () {
      // count 3: 5 (2-byte), 300 (minimal), 7 (3-byte), then filler so the
      // word-wise element path is reached rather than only the tail path.
      final got = _decodeBothWays([
        0x0B, 0x03, //           array id 1, count 3
        0x85, 0x00, //           5, non-minimal
        0xAC, 0x02, //           300, minimal
        0x87, 0x80, 0x00, //     7, non-minimal
        0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01,
      ], sofab.DecodeStatus.complete);
      expect(got.arrays, [
        [5, 300, 7],
      ]);
    });
  });

  // CORELIB_PLAN §7.2 item 5b — tolerance, at the *describing* words rather
  // than at values: "input that is non-canonical but well-formed MUST decode to
  // the value it denotes and re-encode canonically, never INVALID". These are
  // the cases "a majority-vote conformance check cannot catch, since
  // implementations may be uniformly too strict".
  group('non-minimal varints at the describing words (§7.2 item 5b)', () {
    test('a field header', () {
      // (0 << 3) | 0 written as a two-byte varint, then value 5.
      final got = _decodeBothWays([
        0x80, 0x00, //  header, non-minimal
        0x05,
      ], sofab.DecodeStatus.complete);
      expect(got.values, [5]);
    });

    test('a two-byte field header written in three bytes', () {
      // id 130, unsigned: (130 << 3) | 0 = 1040, minimal is 2 bytes.
      final got = _decodeBothWays([
        0x90, 0x88, 0x00, //  1040, non-minimal
        0x07,
      ], sofab.DecodeStatus.complete);
      expect(got.values, [7]);
    });

    test('a fixlen_word', () {
      // string id 0, length 3: word (3 << 3) | 2 = 26, written non-minimally.
      final got = _decodeBothWays([
        0x02, //              header id 0, fixlen
        0x9a, 0x00, //        fixlen_word 26, non-minimal
        0x61, 0x62, 0x63, //  "abc"
      ], sofab.DecodeStatus.complete);
      expect(got.events, ['STR:0:abc']);
    });

    test('an element count', () {
      final got = _decodeBothWays([
        0x03, //        array id 0, unsigned
        0x83, 0x00, //  count 3, non-minimal
        0x01, 0x02, 0x03,
      ], sofab.DecodeStatus.complete);
      expect(got.arrays, [
        [1, 2, 3],
      ]);
    });

    test('a fixlen-array count and its shared word', () {
      final got = _decodeBothWays([
        0x05, //        array id 0, fixlen
        0x81, 0x00, //  count 1, non-minimal
        0xa0, 0x00, //  fixlen_word (4 << 3) | fp32 = 32, non-minimal
        0x00, 0x00, 0x80, 0x3f, // 1.0f
      ], sofab.DecodeStatus.complete);
      expect(got.events, isEmpty);
    });

    test('a sequence-end header whose id is non-zero re-encodes as 0x07', () {
      // §4.9: the id of a sequence-end header is discarded. "a sequence-end
      // header whose id is non-zero but within ID_MAX MUST decode as an
      // ordinary sequence end and re-encode as 0x07".
      final got = _decodeBothWays([
        0x0e, //  sequence start, id 1
        0x00, 0x05, //  child: unsigned id 0 = 5
        0x2f, //  sequence end with id 5 — (5 << 3) | 7
      ], sofab.DecodeStatus.complete);
      expect(got.events, ['SEQ:1', 'END']);
      expect(got.values, [5]);

      final re = sofab.Encoder.encodeToBytes((e) {
        e.beginSequenceLazy(1);
        e.writeUnsigned(0, 5);
        e.endSequence();
      });
      expect(re, [0x0e, 0x00, 0x05, 0x07]);
    });

    test('a sequence-end header written as a non-minimal varint', () {
      final got = _decodeBothWays([
        0x0e, //        sequence start, id 1
        0x00, 0x05,
        0x87, 0x00, //  end marker 0x07, non-minimal
      ], sofab.DecodeStatus.complete);
      expect(got.events, ['SEQ:1', 'END']);
    });
  });

  group('the 64-bit bound is on the encoding (CORELIB_PLAN §4.1)', () {
    test('u64 max decodes to the all-ones bit pattern', () {
      final got = _decodeBothWays([
        0x00,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x01,
      ], sofab.DecodeStatus.complete);
      expect(got.values, [-1]); // 2^64-1 as a Dart 64-bit int
    });

    test('an eleventh byte is INVALID even when it contributes nothing', () {
      _decodeBothWays([
        0x00,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x00,
      ], sofab.DecodeStatus.invalid);
    });

    test('a tenth byte above 0x01 is INVALID', () {
      _decodeBothWays([
        0x00,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x02,
      ], sofab.DecodeStatus.invalid);
    });

    test('an over-long array element is INVALID', () {
      _decodeBothWays([
        0x0B, 0x01, //           array id 1, count 1
        0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00,
      ], sofab.DecodeStatus.invalid);
    });
  });

  group('truncation stays INCOMPLETE', () {
    test('a varint cut mid-stream', () {
      for (var keep = 1; keep <= 9; keep++) {
        final bytes = <int>[0x00];
        bytes.addAll(List<int>.filled(keep, 0x80));
        _decodeBothWays(bytes, sofab.DecodeStatus.incomplete);
      }
    });

    test('an array whose element run is cut short', () {
      _decodeBothWays([0x0B, 0x04, 0x01, 0x02], sofab.DecodeStatus.incomplete);
    });
  });
}
