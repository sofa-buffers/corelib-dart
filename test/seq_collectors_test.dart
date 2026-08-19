import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// The wrapper-array element collectors.
///
/// Every case decodes real bytes rather than calling a callback by hand: the
/// rules under test — placement at the element id, gap fill, the capacity and
/// `maxlen` bounds, the §7.3 skip — are only meaningful in the order the
/// decoder delivers things in.
void main() {
  /// Encodes one sequence field (id 1) and decodes it into `collector`.
  sofab.DecodeStatus run(
    void Function(sofab.Encoder) body,
    sofab.MessageVisitor collector,
  ) {
    final out = BytesBuilder(copy: true);
    final enc = sofab.Encoder(out.add, buffer: Uint8List(256));
    enc.beginSequenceLazy(1);
    body(enc);
    enc.endSequence();
    enc.flush();
    return sofab.Decoder.decode(out.takeBytes(), _Root(collector));
  }

  group('StringSeq', () {
    test('places each element at its id and fills the gap it leaves', () {
      final out = <String>[];
      final st = run((e) {
        e.writeString(0, 'a');
        e.writeString(2, 'c'); // id 1 omitted: equal to the element default
      }, sofab.StringSeq(out, -1, -1));
      expect(st, sofab.DecodeStatus.complete);
      expect(out, ['a', '', 'c']); // length is highest id + 1, not the count
    });

    test(
      'an id at the declared capacity is INVALID, and nothing is placed',
      () {
        final out = <String>[];
        final st = run(
          (e) => e.writeString(2, 'x'),
          sofab.StringSeq(out, 2, -1),
        );
        expect(st, sofab.DecodeStatus.invalid);
        expect(out, isEmpty);
      },
    );

    test('an element past its declared maxlen is INVALID', () {
      final out = <String>[];
      expect(
        run((e) => e.writeString(0, 'abcd'), sofab.StringSeq(out, -1, 3)),
        sofab.DecodeStatus.invalid,
      );
      // ...and the control one byte shorter decodes.
      final ok = <String>[];
      expect(
        run((e) => e.writeString(0, 'abc'), sofab.StringSeq(ok, -1, 3)),
        sofab.DecodeStatus.complete,
      );
      expect(ok, ['abc']);
    });

    test('invalid UTF-8 at a materialized element is INVALID', () {
      // Hand-built: the encoder will not emit a string field that is not UTF-8.
      //   0e        field 1, sequence start
      //   02        element 0, fixlen
      //   12        fixlen word: length 2, subtype string
      //   ff fe     two bytes that are not valid UTF-8
      //   07        sequence end
      final bytes = Uint8List.fromList([0x0e, 0x02, 0x12, 0xff, 0xfe, 0x07]);
      final out = <String>[];
      expect(
        sofab.Decoder.decode(bytes, _Root(sofab.StringSeq(out, -1, -1))),
        sofab.DecodeStatus.invalid,
      );
      expect(out, isEmpty);
    });

    test(
      'a blob element does not belong to a string array: skipped, not rejected',
      () {
        final out = <String>[];
        final st = run(
          (e) => e.writeBlob(0, Uint8List.fromList([1, 2, 3])),
          sofab.StringSeq(out, 1, 1),
        );
        // §7.3 wins over the schema bound: the element is not this array's, so
        // neither its id nor its length is measured against this array's.
        expect(st, sofab.DecodeStatus.complete);
        expect(out, isEmpty);
      },
    );
  });

  group('BlobSeq', () {
    test('copies the bytes, so the result outlives the decode buffer', () {
      final out = <Uint8List>[];
      final st = run(
        (e) => e.writeBlob(1, Uint8List.fromList([7, 8])),
        sofab.BlobSeq(out, -1, -1),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out.length, 2);
      expect(out[0], isEmpty); // the gap
      expect(out[1], [7, 8]);
    });

    test('bounds behave as StringSeq\'s', () {
      final over = <Uint8List>[];
      expect(
        run(
          (e) => e.writeBlob(0, Uint8List.fromList([1, 2, 3])),
          sofab.BlobSeq(over, -1, 2),
        ),
        sofab.DecodeStatus.invalid,
      );
      final past = <Uint8List>[];
      expect(
        run((e) => e.writeBlob(3, Uint8List(0)), sofab.BlobSeq(past, 3, -1)),
        sofab.DecodeStatus.invalid,
      );
    });
  });

  group('IntMatrixSeq', () {
    test('collects rows and bounds each element to its declared width', () {
      final out = <List<int>>[];
      final st = run((e) {
        e.writeUnsignedArray(0, [1, 2]);
        e.writeUnsignedArray(1, [3]);
      }, sofab.IntMatrixSeq(out, -1, false, 0, 255));
      expect(st, sofab.DecodeStatus.complete);
      expect(out, [
        [1, 2],
        [3],
      ]);

      final over = <List<int>>[];
      expect(
        run(
          (e) => e.writeUnsignedArray(0, [256]),
          sofab.IntMatrixSeq(over, -1, false, 0, 255),
        ),
        sofab.DecodeStatus.invalid,
      );
    });

    test('a signed row is not an unsigned array\'s element (§7.3)', () {
      final out = <List<int>>[];
      final st = run(
        (e) => e.writeSignedArray(0, [-1]),
        sofab.IntMatrixSeq(out, 1, false, 0, 255),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out, isEmpty);
    });
  });

  group('DoubleMatrixSeq', () {
    test('an fp32 row keeps a signaling NaN bit-for-bit', () {
      final snan = Float32List(1);
      Uint8List.sublistView(snan).setAll(0, [0x01, 0x00, 0xC0, 0x7F]);
      final out = <List<double>>[];
      final st = run(
        (e) => e.writeFp32Array(0, snan),
        sofab.DoubleMatrixSeq(out, -1, false),
      );
      expect(st, sofab.DecodeStatus.complete);
      final got = Float32List.fromList(out[0]);
      expect(Uint8List.sublistView(got), Uint8List.sublistView(snan));
    });

    test('an fp64 row is not an fp32 array\'s element (§7.3)', () {
      final out = <List<double>>[];
      final st = run(
        (e) => e.writeFp64Array(0, Float64List.fromList([1.5])),
        sofab.DoubleMatrixSeq(out, -1, false),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out, isEmpty);
    });
  });

  group('BoolMatrixSeq', () {
    test('any non-zero element is true', () {
      final out = <List<bool>>[];
      final st = run(
        (e) => e.writeUnsignedArray(0, [0, 1, 2]),
        sofab.BoolMatrixSeq(out, -1),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out, [
        [false, true, true],
      ]);
    });
  });

  group('copyFp32', () {
    test('grows to n and preserves the source bytes exactly', () {
      final src = Float32List.fromList([1.5, -2.25]);
      final got = sofab.copyFp32(src, 4);
      expect(got.length, 4);
      expect(got.sublist(0, 2), [1.5, -2.25]);
      expect(got[2], 0.0);
    });

    test('never shrinks below the source', () {
      final src = Float32List.fromList([1, 2, 3]);
      expect(sofab.copyFp32(src, 1).length, 3);
    });
  });
}

/// Routes the one sequence field to the collector under test.
class _Root extends sofab.VisitorBase {
  _Root(this.child);
  final sofab.MessageVisitor child;

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => id == 1 ? child : null;
}
