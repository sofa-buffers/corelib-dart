import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The streaming decoder's **bulk fast paths** must be invisible.
///
/// `Decoder.feed` does not walk a chunk byte by byte when it does not have to:
/// it lifts a whole varint out of the chunk, reads a run of integer-array
/// elements word-wise, and moves an opaque payload in one go. Which of those
/// applies depends on where the chunk boundaries happen to fall, so the same
/// bytes take a different route through the decoder for every chunk size — and
/// every route has to produce the *same* visitor calls and the *same*
/// `DecodeStatus` as the one-shot contiguous decode, including where that is
/// INVALID or INCOMPLETE.
///
/// The shared conformance vectors are all small messages; these cases are the
/// ones big and wide enough to actually enter the bulk paths (a maximal 10-byte
/// varint, a 1000-element array, a payload longer than a chunk).
void main() {
  group('every chunk size agrees with the one-shot decode', () {
    for (final c in _cases) {
      test(c.name, () {
        final bytes = c.bytes;

        final oneShot = RecordingVisitor();
        final expectedStatus = sofab.Decoder.decode(bytes, oneShot);

        for (final size in const [
          1,
          2,
          3,
          4,
          5,
          7,
          8,
          9,
          10,
          11,
          16,
          64,
          4096,
        ]) {
          final rec = RecordingVisitor();
          final dec = sofab.Decoder(rec);
          var st = sofab.DecodeStatus.complete;
          for (var i = 0; i < bytes.length; i += size) {
            final end = i + size < bytes.length ? i + size : bytes.length;
            st = dec.feed(Uint8List.sublistView(bytes, i, end));
          }
          if (bytes.isEmpty) st = dec.feed(Uint8List(0));
          expect(st, expectedStatus, reason: '${c.name} @ chunk size $size');
          expect(rec.events, oneShot.events, reason: '${c.name} @ size $size');
        }
      });
    }
  });

  test('a chunk that is not a Uint8List decodes to the same bytes', () {
    // `feed` normalizes to `Uint8List` up front; the truncation that does must
    // match the per-byte mask it replaced, including for out-of-range ints.
    final bytes = sofab.Encoder.encodeToBytes((e) {
      e.writeUnsigned(1, 300);
      e.writeString(2, 'plain list');
    });
    final wide = <int>[for (final b in bytes) b | 0x100]; // same low 8 bits
    final rec = RecordingVisitor();
    expect(sofab.Decoder(rec).feed(wide), sofab.DecodeStatus.complete);
    expect(rec.events, ['U:1:300', 'STR:2:plain list']);
  });

  test('two decoders interleaving a split float payload do not collide', () {
    // Each decoder stages a float payload of its own; feeding them alternately
    // one byte at a time would corrupt both if that staging were shared.
    final a = sofab.Encoder.encodeToBytes((e) => e.writeFp64(1, 1.5));
    final b = sofab.Encoder.encodeToBytes((e) => e.writeFp64(1, -2.25));
    final ra = RecordingVisitor(), rb = RecordingVisitor();
    final da = sofab.Decoder(ra), db = sofab.Decoder(rb);
    var sa = sofab.DecodeStatus.incomplete, sb = sofab.DecodeStatus.incomplete;
    for (var i = 0; i < a.length; i++) {
      sa = da.feed(Uint8List.sublistView(a, i, i + 1));
      sb = db.feed(Uint8List.sublistView(b, i, i + 1));
    }
    expect(sa, sofab.DecodeStatus.complete);
    expect(sb, sofab.DecodeStatus.complete);
    expect(ra.events, ['F64:1:${fp64Hex(1.5)}']);
    expect(rb.events, ['F64:1:${fp64Hex(-2.25)}']);
  });

  group('a declared element width is applied inside a bulk run', () {
    // The run decodes many elements before anything is delivered, so the width
    // check has to cover the elements it just took — wherever in the run the
    // offender sits, and whatever the array does afterwards (§7.1, §5.2).
    for (final at in const [0, 1, 7, 40]) {
      test('element $at over width → INVALID at every chunk size', () {
        final values = List<int>.filled(64, 1);
        values[at] = 0x1FFFF; // beyond u16
        final bytes = sofab.Encoder.encodeToBytes(
          (e) => e.writeUnsignedArray(3, values),
        );
        for (final size in const [1, 3, 10, 11, 64, 4096]) {
          final dec = sofab.Decoder(_U16Visitor());
          var st = sofab.DecodeStatus.complete;
          for (var i = 0; i < bytes.length; i += size) {
            final end = i + size < bytes.length ? i + size : bytes.length;
            st = dec.feed(Uint8List.sublistView(bytes, i, end));
          }
          expect(st, sofab.DecodeStatus.invalid, reason: 'chunk size $size');
        }
      });
    }

    test('a truncated array still reports the over-width element', () {
      final values = List<int>.filled(64, 1);
      values[3] = 0x1FFFF;
      final full = sofab.Encoder.encodeToBytes(
        (e) => e.writeUnsignedArray(3, values),
      );
      final cut = Uint8List.sublistView(full, 0, 20);
      final dec = sofab.Decoder(_U16Visitor());
      expect(dec.feed(cut), sofab.DecodeStatus.invalid);
    });

    test('all elements in range still completes', () {
      final bytes = sofab.Encoder.encodeToBytes(
        (e) => e.writeUnsignedArray(3, List<int>.filled(64, 0xFFFF)),
      );
      expect(
        sofab.Decoder(_U16Visitor()).feed(bytes),
        sofab.DecodeStatus.complete,
      );
    });
  });
}

/// A schema-bound consumer declaring `u16` elements for array field 3.
class _U16Visitor extends sofab.MessageVisitor {
  @override
  sofab.ElemRange? onArrayElemBound(int id, sofab.ArrayKind kind) =>
      id == 3 && kind == sofab.ArrayKind.unsigned
      ? const sofab.ElemRange(0, 0xFFFF)
      : null;
}

class _Case {
  const _Case(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Values spanning every varint length 1..10, so a chunk boundary can fall
/// anywhere inside any of them.
final List<int> _everyVarintLength = <int>[
  0,
  0x7F,
  0x3FFF,
  0x1FFFFF,
  0xFFFFFFF,
  0x7FFFFFFFF,
  0x3FFFFFFFFFF,
  0x1FFFFFFFFFFFF,
  0xFFFFFFFFFFFFFF,
  0x7FFFFFFFFFFFFFFF,
  -1, // bit 63 set: the 10-byte maximum
];

final List<_Case> _cases = <_Case>[
  _Case(
    'scalars of every varint length',
    sofab.Encoder.encodeToBytes((e) {
      for (var i = 0; i < _everyVarintLength.length; i++) {
        e.writeUnsigned(i, _everyVarintLength[i]);
        e.writeSigned(100 + i, _everyVarintLength[i]);
      }
    }, bufferSize: 8192),
  ),
  _Case(
    'a 1000-element unsigned array of wide values',
    sofab.Encoder.encodeToBytes(
      (e) => e.writeUnsignedArray(
        1,
        Int64List.fromList(
          List<int>.generate(1000, (i) => i * 0x9E3779B97F4A7C15),
        ),
      ),
      bufferSize: 1 << 16,
    ),
  ),
  _Case(
    'a 1000-element signed array of wide values',
    sofab.Encoder.encodeToBytes(
      (e) => e.writeSignedArray(
        1,
        Int64List.fromList(
          List<int>.generate(1000, (i) => (i.isEven ? 1 : -1) * i * 7919),
        ),
      ),
      bufferSize: 1 << 16,
    ),
  ),
  _Case(
    'a long string, blob and fp arrays',
    sofab.Encoder.encodeToBytes((e) {
      e.writeString(1, 'x' * 500);
      e.writeBlob(2, Uint8List.fromList(List<int>.generate(300, (i) => i)));
      e.writeFp32Array(
        3,
        Float32List.fromList(<double>[for (var i = 0; i < 200; i++) i * 0.5]),
      );
      e.writeFp64Array(
        4,
        Float64List.fromList(<double>[for (var i = 0; i < 200; i++) i * 1.5]),
      );
      e.writeFp32(5, 3.5);
      e.writeFp64(6, -7.25);
    }, bufferSize: 1 << 16),
  ),
  _Case(
    'arrays nested in sequences',
    sofab.Encoder.encodeToBytes((e) {
      for (var k = 0; k < 8; k++) {
        e.beginSequenceLazy(k);
        e.writeUnsignedArray(1, List<int>.generate(40, (i) => i * 0x1234567));
        e.writeString(2, 'seq-$k');
        e.endSequence();
      }
    }, bufferSize: 1 << 16),
  ),
  // A malformed 10-byte element varint (11th continuation byte) in the middle
  // of a long array: INVALID however the chunking falls.
  _Case(
    'a malformed 10-byte element varint mid-array',
    Uint8List.fromList(<int>[
      0x0B, // id 1, arrayUnsigned
      0x0A, // count 10
      for (var i = 0; i < 4; i++) 0x01,
      // 10 continuation bytes then a terminator: past the 64-bit bound.
      0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
      for (var i = 0; i < 5; i++) 0x01,
    ]),
  ),
  // A 10-byte element varint whose last byte carries more than bit 63.
  _Case(
    'an element varint past the 64-bit bound',
    Uint8List.fromList(<int>[
      0x0B,
      0x03,
      0x01,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0x02,
      0x01,
    ]),
  ),
  // The maximum legal element varint, so the bulk run's 10-byte arm is taken
  // for a value it must accept.
  _Case(
    'the maximum legal element varint',
    Uint8List.fromList(<int>[
      0x0B,
      0x03,
      0x01,
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
      0x02,
    ]),
  ),
  // A materialized string whose bytes are not valid UTF-8 is INVALID (§6.4) —
  // and the payload reaches the check by a different route for a one-byte chunk
  // (the byte-wise reader) than for a whole one (the bulk move).
  _Case(
    'a short string that is not valid UTF-8',
    Uint8List.fromList(<int>[0x0A, 0x12, 0xFF, 0xFE]),
  ),
  _Case(
    'a long string that is not valid UTF-8',
    // Long enough that a whole chunk delivers the payload through the bulk
    // move, where the short one above is delivered byte-wise either way.
    Uint8List.fromList(<int>[
      0x0A, 0x42, //
      0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0xFF,
    ]),
  ),
  // fixlen words the format rejects outright, seen by the streaming reader.
  _Case(
    'an fp32 fixlen word whose length is not 4',
    Uint8List.fromList(<int>[0x0A, 0x28, 0, 0, 0, 0, 0]),
  ),
  _Case(
    'an fp64 fixlen word whose length is not 8',
    Uint8List.fromList(<int>[0x0A, 0x29, 0, 0, 0, 0, 0]),
  ),
  _Case(
    'a reserved fixlen subtype',
    Uint8List.fromList(<int>[0x0A, 0x0C, 0, 0]),
  ),
  // Truncated one element short: INCOMPLETE, not INVALID, at every chunking.
  _Case(
    'an array cut one element short',
    Uint8List.fromList(<int>[
      0x0B,
      0x05,
      for (var i = 0; i < 4; i++) 0x81,
      0x01,
    ]),
  ),
];
