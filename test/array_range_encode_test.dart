import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// [sofab.Encoder.writeUnsignedArrayInRange] and
/// [sofab.Encoder.writeSignedArrayInRange] refuse an element outside the
/// declared width with `invalidArgument` (CORELIB_PLAN §6.3) — the encode-side
/// twin of the decoder's element-width check. The width is the caller's
/// argument; the codec holds none of its own.
///
/// Every refusal is paired with the in-range control one step away, on both
/// element loops (the bulk one that fits the buffer, and the flushing one a
/// small streaming buffer takes), and on both list shapes (`Int64List`, plain
/// `List`), so what is pinned is the bound, not a blanket reject.
void main() {
  // Encodes through a buffer of [buffer] bytes and a collecting sink.
  Uint8List encode(void Function(sofab.Encoder e) build, {int buffer = 256}) {
    final out = BytesBuilder();
    final enc = sofab.Encoder(out.add, buffer: Uint8List(buffer));
    build(enc);
    enc.flush();
    return out.toBytes();
  }

  String hex(void Function(sofab.Encoder e) build, {int buffer = 256}) =>
      bytesToHex(encode(build, buffer: buffer));

  Matcher refused(String what) => throwsA(
    isA<sofab.SofabException>()
        .having((x) => x.code, 'code', sofab.SofabError.invalidArgument)
        .having((x) => x.message, 'message', contains(what)),
  );

  for (final buffer in const [256, 2]) {
    final loop = buffer == 256 ? 'bulk loop' : 'flushing loop';

    group('unsigned, $loop', () {
      test('at the bound encodes exactly as the unchecked writer', () {
        for (final vals in [
          Int64List.fromList([0, 1, 255]),
          [0, 1, 255],
        ]) {
          expect(
            hex(
              (e) => e.writeUnsignedArrayInRange(3, vals, 3, 0, 255),
              buffer: buffer,
            ),
            hex((e) => e.writeUnsignedArray(3, vals), buffer: buffer),
          );
        }
      });

      test('one past the bound is refused', () {
        for (final vals in [
          Int64List.fromList([1, 256]),
          [1, 256],
        ]) {
          expect(
            () => encode(
              (e) => e.writeUnsignedArrayInRange(3, vals, 2, 0, 255),
              buffer: buffer,
            ),
            refused('array id 3: an element is outside'),
          );
        }
      });

      test('a negative element (>= 2^63 unsigned) is refused', () {
        expect(
          () => encode(
            (e) => e.writeUnsignedArrayInRange(3, [-1], 1, 0, 4294967295),
            buffer: buffer,
          ),
          refused('array id 3: an element is outside'),
        );
      });

      test('2^32 in a u32 array is refused, 2^32-1 is not', () {
        expect(
          () => encode(
            (e) => e.writeUnsignedArrayInRange(
              1,
              [1, 2, 4294967296],
              3,
              0,
              4294967295,
            ),
            buffer: buffer,
          ),
          refused('array id 1: an element is outside'),
        );
        expect(
          hex(
            (e) =>
                e.writeUnsignedArrayInRange(1, [4294967295], 1, 0, 4294967295),
            buffer: buffer,
          ),
          '0b01ffffffff0f',
        );
      });

      test('an element past count is not looked at', () {
        expect(
          hex(
            (e) => e.writeUnsignedArrayInRange(
              3,
              Int64List.fromList([7, 9999]),
              1,
              0,
              255,
            ),
            buffer: buffer,
          ),
          '1b0107',
        );
      });
    });

    group('signed, $loop', () {
      test('both ends of the width encode as the unchecked writer', () {
        for (final vals in [
          Int64List.fromList([-32768, 0, 32767]),
          [-32768, 0, 32767],
        ]) {
          expect(
            hex(
              (e) => e.writeSignedArrayInRange(2, vals, 3, -32768, 32767),
              buffer: buffer,
            ),
            hex((e) => e.writeSignedArray(2, vals), buffer: buffer),
          );
        }
      });

      test('an element past count is not looked at', () {
        final vals = Int64List.fromList([-32768, -1, 32767, 99999]);
        expect(
          hex(
            (e) => e.writeSignedArrayInRange(2, vals, 3, -32768, 32767),
            buffer: buffer,
          ),
          hex((e) => e.writeSignedArray(2, vals, 3), buffer: buffer),
        );
      });

      test('one below the width is refused', () {
        for (final vals in [
          Int64List.fromList([0, -32769]),
          [0, -32769],
        ]) {
          expect(
            () => encode(
              (e) => e.writeSignedArrayInRange(2, vals, 2, -32768, 32767),
              buffer: buffer,
            ),
            refused('array id 2: an element is outside'),
          );
        }
      });

      test('one above the width is refused', () {
        for (final vals in [
          Int64List.fromList([32768]),
          [32768],
        ]) {
          expect(
            () => encode(
              (e) => e.writeSignedArrayInRange(2, vals, 1, -32768, 32767),
              buffer: buffer,
            ),
            refused('array id 2: an element is outside'),
          );
        }
      });
    });
  }

  group('a count outside the list is refused before any byte', () {
    for (final count in const [-1, 3]) {
      test('unsigned, count $count', () {
        final out = <Uint8List>[];
        final enc = sofab.Encoder(out.add, buffer: Uint8List(64));
        expect(
          () => enc.writeUnsignedArrayInRange(0, [1, 2], count, 0, 255),
          refused('count $count out of range 0..2'),
        );
        enc.flush();
        expect(out.expand((b) => b), isEmpty);
      });
      test('signed, count $count', () {
        final out = <Uint8List>[];
        final enc = sofab.Encoder(out.add, buffer: Uint8List(64));
        expect(
          () => enc.writeSignedArrayInRange(
            0,
            Int64List.fromList([1, 2]),
            count,
            -128,
            127,
          ),
          refused('count $count out of range 0..2'),
        );
        enc.flush();
        expect(out.expand((b) => b), isEmpty);
      });
    }
  });

  test('the unchecked writers bound nothing', () {
    expect(
      hex((e) => e.writeUnsignedArray(0, [4294967296])),
      '030180808080'
      '10',
    );
    expect(
      hex((e) => e.writeSignedArray(0, [70000])),
      hex((e) => e.writeSignedArray(0, [70000], 1)),
    );
  });
}
