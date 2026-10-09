import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// An integer array written with a declared element width ([sofab.ElemRange])
/// refuses an element outside it with `invalidArgument` (CORELIB_PLAN §6.3) —
/// the encode-side twin of the decoder's element-width check. The width is the
/// caller's argument; the codec holds none of its own.
///
/// Every refusal is paired with the in-range control one step away, on both
/// element loops (the bulk one that fits the buffer, and the flushing one a
/// small streaming buffer takes), so what is pinned is the bound, not a blanket
/// reject.
void main() {
  const u8 = sofab.ElemRange(0, 255);
  const u32 = sofab.ElemRange(0, 4294967295);
  const i16 = sofab.ElemRange(-32768, 32767);

  // Encodes through a buffer of [buffer] bytes and a collecting sink.
  Uint8List encode(void Function(sofab.Encoder e) build, {int buffer = 256}) {
    final out = BytesBuilder();
    final enc = sofab.Encoder(out.add, buffer: Uint8List(buffer));
    build(enc);
    enc.flush();
    return out.toBytes();
  }

  Matcher refused(String what) => throwsA(
    isA<sofab.SofabException>()
        .having((x) => x.code, 'code', sofab.SofabError.invalidArgument)
        .having((x) => x.message, 'message', contains(what)),
  );

  for (final buffer in const [256, 2]) {
    final loop = buffer == 256 ? 'bulk loop' : 'flushing loop';

    group('unsigned, $loop', () {
      test('at the bound encodes exactly as without a range', () {
        final vals = Int64List.fromList([0, 1, 255]);
        expect(
          bytesToHex(
            encode(
              (e) => e.writeUnsignedArray(3, vals, null, u8),
              buffer: buffer,
            ),
          ),
          bytesToHex(
            encode((e) => e.writeUnsignedArray(3, vals), buffer: buffer),
          ),
        );
      });

      test('one past the bound is refused', () {
        expect(
          () => encode(
            (e) => e.writeUnsignedArray(3, Int64List.fromList([1, 256]), 2, u8),
            buffer: buffer,
          ),
          refused('field 3: an element is outside'),
        );
      });

      test('a negative element (>= 2^63 unsigned) is refused', () {
        expect(
          () => encode(
            (e) => e.writeUnsignedArray(3, [-1], null, u32),
            buffer: buffer,
          ),
          refused('field 3: an element is outside'),
        );
      });

      test('2^32 in a u32 array is refused, 2^32-1 is not', () {
        expect(
          () => encode(
            (e) => e.writeUnsignedArray(1, [1, 2, 4294967296], null, u32),
            buffer: buffer,
          ),
          refused('field 1: an element is outside'),
        );
        expect(
          bytesToHex(
            encode(
              (e) => e.writeUnsignedArray(1, [4294967295], null, u32),
              buffer: buffer,
            ),
          ),
          '0b01ffffffff0f',
        );
      });

      test('an element past count is not looked at', () {
        expect(
          bytesToHex(
            encode(
              (e) =>
                  e.writeUnsignedArray(3, Int64List.fromList([7, 9999]), 1, u8),
              buffer: buffer,
            ),
          ),
          '1b0107',
        );
      });
    });

    group('signed, $loop', () {
      test('both ends of the width encode', () {
        final vals = [-32768, 0, 32767];
        expect(
          bytesToHex(
            encode(
              (e) => e.writeSignedArray(2, vals, null, i16),
              buffer: buffer,
            ),
          ),
          bytesToHex(
            encode((e) => e.writeSignedArray(2, vals), buffer: buffer),
          ),
        );
      });

      test('an Int64List inside the width encodes as without a range', () {
        final vals = Int64List.fromList([-32768, -1, 32767, 9999]);
        expect(
          bytesToHex(
            encode((e) => e.writeSignedArray(2, vals, 3, i16), buffer: buffer),
          ),
          bytesToHex(
            encode((e) => e.writeSignedArray(2, vals, 3), buffer: buffer),
          ),
        );
      });

      test('one below the width is refused', () {
        expect(
          () => encode(
            (e) => e.writeSignedArray(2, [0, -32769], null, i16),
            buffer: buffer,
          ),
          refused('field 2: an element is outside'),
        );
      });

      test('one above the width is refused', () {
        expect(
          () => encode(
            (e) => e.writeSignedArray(2, Int64List.fromList([32768]), 1, i16),
            buffer: buffer,
          ),
          refused('field 2: an element is outside'),
        );
      });
    });
  }

  test('without a range nothing is bounded', () {
    expect(
      bytesToHex(encode((e) => e.writeUnsignedArray(0, [4294967296]))),
      '0301808080801'
      '0',
    );
    expect(
      bytesToHex(encode((e) => e.writeSignedArray(0, [70000]))),
      bytesToHex(encode((e) => e.writeSignedArray(0, [70000], 1))),
    );
  });

  test('ElemRange.boolean bounds nothing on encode', () {
    for (final buffer in const [256, 2]) {
      expect(
        bytesToHex(
          encode(
            (e) =>
                e.writeUnsignedArray(0, [0, 1], null, sofab.ElemRange.boolean),
            buffer: buffer,
          ),
        ),
        '03020001',
      );
      expect(
        bytesToHex(
          encode(
            (e) => e.writeSignedArray(0, [-1], null, sofab.ElemRange.boolean),
            buffer: buffer,
          ),
        ),
        '040101',
      );
    }
  });
}
