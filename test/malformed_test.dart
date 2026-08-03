import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Malformed-input tests (CORELIB_PLAN §5.2, §7.2 item 5): each must return the
/// INVALID decode outcome — a well-defined error — never crash.
void main() {
  sofab.DecodeStatus decode(String hex) =>
      sofab.Decoder.decode(hexToBytes(hex), RecordingVisitor());

  test('overlong varint (>64 bits) → INVALID', () {
    // 11 continuation bytes for a value varint: header id0 unsigned, then a
    // varint that never terminates within 10 bytes.
    final bytes = Uint8List.fromList([
      0x00, // header id0 unsigned
      0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01,
    ]);
    expect(
      sofab.Decoder.decode(bytes, RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('varint with payload bits beyond bit 63 → INVALID', () {
    // 10th byte carries more than one payload bit.
    final bytes = Uint8List.fromList([
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
    ]);
    expect(
      sofab.Decoder.decode(bytes, RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('unbalanced sequence end (no open sequence) → INVALID', () {
    expect(decode('07'), sofab.DecodeStatus.invalid);
  });

  test('sequence end after a balanced sequence → INVALID', () {
    // seq start id0, seq end, then a stray seq end.
    expect(decode('060707'), sofab.DecodeStatus.invalid);
  });

  test('reserved fixlen subtype (0x4) → INVALID', () {
    // header id0 fixlen; fixlen_word = (0<<3)|4 = 0x04 (reserved subtype).
    expect(decode('0204'), sofab.DecodeStatus.invalid);
  });

  test('fp32 fixlen with wrong length → INVALID', () {
    // fixlen_word = (5<<3)|0 = 0x28: fp32 must be exactly 4 bytes.
    expect(
      decode(
        '0228'
        '0000000000',
      ),
      sofab.DecodeStatus.invalid,
    );
  });

  test('fp64 fixlen with wrong length (proves early check) → INVALID', () {
    // 56 0a 59 : nested fp64 whose fixlen_word declares length 11, then
    // truncates — the word alone proves it malformed (CORELIB_PLAN §5.2).
    expect(decode('560a59'), sofab.DecodeStatus.invalid);
  });

  test('string/blob not allowed in a fixlen array → INVALID', () {
    // array-fixlen header id0 (0x05), count 1, fixlen_word (1<<3)|2 string.
    expect(
      decode(
        '0501'
        '0a'
        '61',
      ),
      sofab.DecodeStatus.invalid,
    );
  });

  test('length above FIXLEN_MAX → INVALID', () {
    // fixlen_word encoding a blob length > 2^31-1.
    // word = (2^31 << 3) | 3. Build the varint for it.
    final b = BytesBuilder();
    b.addByte(0x02); // header id0 fixlen
    var word = ((BigInt.from(2147483648) << 3) | BigInt.from(3)).toInt();
    while (true) {
      final lo = word & 0x7f;
      word = word >>> 7;
      if (word == 0) {
        b.addByte(lo);
        break;
      }
      b.addByte(lo | 0x80);
    }
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('array count above ARRAY_MAX → INVALID', () {
    final b = BytesBuilder();
    b.addByte(0x03); // header id0 array-unsigned
    var count = 2147483648; // > ARRAY_MAX
    while (true) {
      final lo = count & 0x7f;
      count = count >>> 7;
      if (count == 0) {
        b.addByte(lo);
        break;
      }
      b.addByte(lo | 0x80);
    }
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('nesting past MAX_DEPTH (256 sequences) → INVALID', () {
    // 256 sequence-start headers (id0 → single byte 0x06) must be rejected.
    final b = BytesBuilder();
    for (var i = 0; i < 256; i++) {
      b.addByte(0x06);
    }
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('exactly MAX_DEPTH (255) sequences is accepted', () {
    final b = BytesBuilder();
    for (var i = 0; i < 255; i++) {
      b.addByte(0x06);
    }
    for (var i = 0; i < 255; i++) {
      b.addByte(0x07);
    }
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.complete,
    );
  });

  test('field id above ID_MAX (2^31) → INVALID', () {
    // header varint (2^31 << 3) | 0 → id 2^31, unsigned, value 5.
    expect(
      decode(
        '8080808040'
        '05',
      ),
      sofab.DecodeStatus.invalid,
    );
  });

  test('field id exactly ID_MAX (2^31-1) is accepted (control)', () {
    // header ((2^31-1) << 3) | 0 → id idMax, unsigned, value 5 — skipped, ok.
    final b = BytesBuilder();
    var header = ((BigInt.from(2147483647) << 3) | BigInt.zero).toInt();
    while (true) {
      final lo = header & 0x7f;
      header = header >>> 7;
      if (header == 0) {
        b.addByte(lo);
        break;
      }
      b.addByte(lo | 0x80);
    }
    b.addByte(0x05); // value 5
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.complete,
    );
  });

  test('over-ID_MAX id on a sequence-end is accepted and discarded (§4.9)', () {
    // 76 — sequenceStart, undeclared id 14 → skipped subtree opened (§5.2).
    // 87 80 80 80 40 — a header varint, wire type 7 (SequenceEnd), id 2^31,
    // one past ID_MAX. §4.9/§6.2: a sequence-end discards its id regardless of
    // value, so this closes the sequence and the message decodes to empty.
    // Crucible F-0054; contrast the value-bearing over-ID_MAX case above.
    expect(decode('768780808040'), sofab.DecodeStatus.complete);
  });

  test('over-ID_MAX id on a sequence-end is accepted on the streaming path', () {
    // Same input, exercising Decoder.feed / _stepHeader — the ID_MAX guard was
    // duplicated across both decode surfaces (§6.5), so both must be checked.
    final d = sofab.Decoder(RecordingVisitor());
    expect(
      d.feed(hexToBytes('768780808040')),
      sofab.DecodeStatus.complete,
    );
  });

  test('seq-end id at ID_MAX still accepted (control, must not regress)', () {
    // header ((2^31-1) << 3) | 7 → sequence-end, id idMax, inside a skipped
    // sequence opened by 0x76 (id 14). Sits under the ceiling; already passing.
    final b = BytesBuilder();
    b.addByte(0x76); // sequenceStart, id 14
    var header = ((BigInt.from(2147483647) << 3) | BigInt.from(7)).toInt();
    while (true) {
      final lo = header & 0x7f;
      header = header >>> 7;
      if (header == 0) {
        b.addByte(lo);
        break;
      }
      b.addByte(lo | 0x80);
    }
    expect(
      sofab.Decoder.decode(b.toBytes(), RecordingVisitor()),
      sofab.DecodeStatus.complete,
    );
  });

  test('INVALID takes precedence over INCOMPLETE when both apply', () {
    // 560a59 is malformed (fp64 wrong length) AND truncated → must be INVALID.
    expect(decode('560a59'), sofab.DecodeStatus.invalid);
  });
}
