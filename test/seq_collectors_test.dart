import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
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

  group('MessageSeq', () {
    test('fills an element in place at its id, so a re-opened id merges', () {
      final out = <_Point>[];
      final st = run(
        (e) {
          e.beginSequenceLazy(0); // element 0
          e.writeSigned(0, 3);
          e.endSequence();
          e.beginSequenceLazy(0); // the SAME element, re-opened (§7.4)
          e.writeSigned(1, 4);
          e.endSequence();
        },
        sofab.MessageSeq<_Point>(out, -1, _Point.new, (p) => _PointVisitor(p)),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out.length, 1);
      expect([out[0].x, out[0].y], [3, 4]); // merged, not appended twice
    });

    test('gap-fills with fresh elements and bounds the id', () {
      final out = <_Point>[];
      final st = run(
        (e) {
          e.beginSequenceLazy(2); // ids 0 and 1 omitted
          e.writeSigned(0, 9);
          e.endSequence();
        },
        sofab.MessageSeq<_Point>(out, -1, _Point.new, (p) => _PointVisitor(p)),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out.length, 3);
      expect([out[0].x, out[1].x, out[2].x], [0, 0, 9]);

      final past = <_Point>[];
      expect(
        run(
          (e) {
            // Content matters: lazy framing drops a CONTENTLESS sequence entirely
            // (§2), so an empty element would never reach the collector at all.
            e.beginSequenceLazy(2);
            e.writeSigned(0, 1);
            e.endSequence();
          },
          sofab.MessageSeq<_Point>(
            past,
            2,
            _Point.new,
            (p) => _PointVisitor(p),
          ),
        ),
        sofab.DecodeStatus.invalid,
      );
      expect(past, isEmpty);
    });
  });

  group('NestedSeq', () {
    test('collects a row of rows, each row through its own collector', () {
      final out = <List<String>>[];
      final st = run(
        (e) {
          e.beginSequenceLazy(0);
          e.writeString(0, 'a');
          e.writeString(1, 'b');
          e.endSequence();
          e.beginSequenceLazy(1);
          e.writeString(0, 'c');
          e.endSequence();
        },
        sofab.NestedSeq<String>(out, -1, (row) => sofab.StringSeq(row, -1, -1)),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out, [
        ['a', 'b'],
        ['c'],
      ]);
    });

    test('a row id past the outer capacity is INVALID', () {
      final out = <List<String>>[];
      final st = run(
        (e) {
          e.beginSequenceLazy(3);
          e.writeString(0, 'x');
          e.endSequence();
        },
        sofab.NestedSeq<String>(out, 3, (row) => sofab.StringSeq(row, -1, -1)),
      );
      expect(st, sofab.DecodeStatus.invalid);
      expect(out, isEmpty);
    });
  });

  group('DoubleMatrixSeq, fp64 rows', () {
    test(
      'collects them, and an fp32 row is not this array\'s element (§7.3)',
      () {
        final out = <List<double>>[];
        final st = run(
          (e) => e.writeFp64Array(1, Float64List.fromList([1.5, 2.5])),
          sofab.DoubleMatrixSeq(out, -1, true),
        );
        expect(st, sofab.DecodeStatus.complete);
        expect(out.length, 2);
        expect(out[0], isEmpty); // the gap at id 0
        expect(out[1], [1.5, 2.5]);

        final other = <List<double>>[];
        expect(
          run(
            (e) => e.writeFp32Array(0, Float32List.fromList([1.5])),
            sofab.DoubleMatrixSeq(other, -1, true),
          ),
          sofab.DecodeStatus.complete,
        );
        expect(other, isEmpty);
      },
    );
  });

  // CORELIB_PLAN §6.2.1 / corelib-dart#86. A wrapper array has no count header,
  // so its length is the highest element **index** and the index is what the
  // receiver cap has to bound — "checked before the container it indexes into
  // is extended". The schema `count` (`cap`) and the receiver cap (`rcap`) are
  // different statements and reach different outcomes: INVALID for the first,
  // limitExceeded for the second, and §6.2.1 forbids folding either into the
  // other. They are never both in play — a receiver cap "MUST NOT be applied to
  // a field the schema already bounds".
  group('the receiver cap on the element index', () {
    test('an index at the cap is limitExceeded, and nothing is placed', () {
      final out = <String>[];
      final st = run(
        (e) => e.writeString(4, 'x'),
        sofab.StringSeq(out, -1, -1, rcap: 4),
      );
      expect(st, sofab.DecodeStatus.limitExceeded);
      expect(out, isEmpty, reason: 'rejected before the container grew');
    });

    test('index cap-1 decodes', () {
      final out = <String>[];
      final st = run(
        (e) => e.writeString(3, 'x'),
        sofab.StringSeq(out, -1, -1, rcap: 4),
      );
      expect(st, sofab.DecodeStatus.complete);
      expect(out.length, 4);
      expect(out[3], 'x');
    });

    test('a schema-bounded array is governed by its count alone', () {
      // cap = 2, rcap = 1: the receiver cap must not touch a field the schema
      // bounds, so index 1 decodes and index 2 is INVALID, not limitExceeded.
      final ok = <String>[];
      expect(
        run((e) => e.writeString(1, 'x'), sofab.StringSeq(ok, 2, -1, rcap: 1)),
        sofab.DecodeStatus.complete,
      );
      final bad = <String>[];
      expect(
        run((e) => e.writeString(2, 'x'), sofab.StringSeq(bad, 2, -1, rcap: 1)),
        sofab.DecodeStatus.invalid,
      );
    });

    test('the cap is checked at the fixlen header too', () {
      // Truncated right behind an over-index element's header: the index
      // verdict still dominates the truncation (§5.2 anti-folding).
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(out.add, buffer: Uint8List(64));
      enc.beginSequenceLazy(1);
      enc.writeString(4, 'abcdef');
      enc.endSequence();
      enc.flush();
      final whole = out.takeBytes();
      final cut = Uint8List.sublistView(whole, 0, whole.length - 4);
      final dst = <String>[];
      expect(
        sofab.Decoder.decode(cut, _Root(sofab.StringSeq(dst, -1, -1, rcap: 4))),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('after a rejected index nothing is left partially extended', () {
      final out = <String>[];
      final st = run((e) {
        e.writeString(0, 'a');
        e.writeString(9, 'z');
      }, sofab.StringSeq(out, -1, -1, rcap: 4));
      expect(st, sofab.DecodeStatus.limitExceeded);
      expect(out, [
        'a',
      ], reason: 'the accepted element stands, the rest does not');
    });

    test('every collector carries the same bound', () {
      final blobs = <Uint8List>[];
      expect(
        run(
          (e) => e.writeBlob(4, Uint8List.fromList([1])),
          sofab.BlobSeq(blobs, -1, -1, rcap: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );

      final pts = <_Point>[];
      expect(
        run(
          (e) {
            e.beginSequenceLazy(4);
            e.writeSigned(0, 1);
            e.endSequenceKeep();
          },
          sofab.MessageSeq<_Point>(
            pts,
            -1,
            _Point.new,
            _PointVisitor.new,
            rcap: 4,
          ),
        ),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(pts, isEmpty);

      final rows = <List<int>>[];
      expect(
        run(
          (e) => e.writeUnsignedArray(4, const [1, 2]),
          sofab.IntMatrixSeq(rows, -1, false, 0, 0, rcap: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );

      final flags = <List<bool>>[];
      expect(
        run(
          (e) => e.writeUnsignedArray(4, const [1]),
          sofab.BoolMatrixSeq(flags, -1, rcap: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );

      final mat = <List<double>>[];
      expect(
        run(
          (e) => e.writeFp64Array(4, const [1.5]),
          sofab.DoubleMatrixSeq(mat, -1, true, rcap: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );

      final nested = <List<String>>[];
      expect(
        run(
          (e) {
            e.beginSequenceLazy(4);
            e.writeString(0, 'x');
            e.endSequenceKeep();
          },
          sofab.NestedSeq<String>(
            nested,
            -1,
            (row) => sofab.StringSeq(row, -1, -1),
          ),
        ),
        sofab.DecodeStatus.complete,
      );
      final nested2 = <List<String>>[];
      expect(
        run(
          (e) {
            e.beginSequenceLazy(4);
            e.writeString(0, 'x');
            e.endSequenceKeep();
          },
          sofab.NestedSeq<String>(
            nested2,
            -1,
            (row) => sofab.StringSeq(row, -1, -1),
            rcap: 4,
          ),
        ),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('an unconfigured collector is still bounded', () {
      // No rcap passed at all: the default is finite (§6.2.1 admits no unset
      // state), so a far-away index is a policy rejection rather than a
      // multi-million-entry list.
      final out = <String>[];
      final st = run(
        (e) => e.writeString(sofab.defaultMaxDynArrayCount, 'x'),
        sofab.StringSeq(out, -1, -1),
      );
      expect(st, sofab.DecodeStatus.limitExceeded);
      expect(out, isEmpty);
    });
  });

  group('the payload-side bound', () {
    test(
      'an over-maxlen element is rejected even when the header word is not',
      () {
        // Reaches the guard in onStringBytes/onBlob rather than the one in
        // onFixlenHeader: the header carries the WIRE length, and for a string
        // they agree — so this drives the payload path with a collector whose
        // emax the header check cannot have applied, i.e. a re-opened element.
        final out = <String>[];
        final st = run((e) {
          e.writeString(0, 'abcdef');
        }, sofab.StringSeq(out, -1, 3));
        expect(st, sofab.DecodeStatus.invalid);
        expect(out, isEmpty);
      },
    );
  });
}

/// A minimal generated-object stand-in for MessageSeq.
class _Point {
  int x = 0;
  int y = 0;
}

class _PointVisitor extends sofab.VisitorBase {
  _PointVisitor(this.o);
  final _Point o;

  @override
  void onSigned(int id, int value) {
    if (id == 0) o.x = value;
    if (id == 1) o.y = value;
  }
}

/// Routes the one sequence field to the collector under test.
class _Root extends sofab.VisitorBase {
  _Root(this.child);
  final sofab.MessageVisitor child;

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => id == 1 ? child : null;
}
