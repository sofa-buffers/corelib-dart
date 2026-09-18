// CORELIB_PLAN §7.2 item 4 — the chunk-lifetime and one-shot-buffer tests:
//
// * **Overwrite every chunk after `feed` returns** — scrub it, and assert the
//   decoded message is unchanged. "Nothing else in this list would notice a
//   decoder that kept a slice into a fed chunk."
// * **Overwrite the one-shot buffer too** — run `decode(buffer)`, scrub the
//   whole buffer, and assert the decoded message is unchanged. "The one-shot
//   path has no view exemption (§6.7.1), and this is the test that proves it; a
//   port that borrows from the buffer it was handed passes every other item on
//   this list."
//
// The second half of this file used to assert the **opposite** — that
// `Decoder.decode` hands the blob/string callbacks a view onto the caller's
// buffer — under the older §9.6, which let a port choose view-or-copy and state
// its choice. §6.7.1 removed the choice: "decode(buffer) copies too … otherwise
// a port's memory behaviour would depend on which entry point was used". Every
// value now lands in a destination the caller supplied (§6.6.3), on both
// surfaces, so scrubbing the input cannot reach it.

import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// `blob` field id 1, payload 'abc': header `(1<<3)|2`, `fixlen_word` `(3<<3)|3`.
Uint8List blobAbc() =>
    Uint8List.fromList([0x0a, 0x1b, 0x61, 0x62, 0x63]); // 'abc'

/// `string` field id 1, payload 'abc': `fixlen_word` `(3<<3)|2`.
Uint8List stringAbc() => Uint8List.fromList([0x0a, 0x1a, 0x61, 0x62, 0x63]);

/// Hands out exactly-sized destinations and retains their storage — the
/// caller's own memory, which is where every decoded value lands.
class _Keeper extends sofab.MessageVisitor {
  sofab.InlineBytes? _blob;
  sofab.InlineString? _string;
  sofab.InlineInt64Array? _ints;
  sofab.InlineFloat64Array? _fp64;

  Uint8List? get blob => _blob?.storage;
  Uint8List? get stringBytes => _string?.storage;
  String? get string => _string?.toString();
  Int64List? get ints => _ints?.storage;
  Float64List? get fp64 => _fp64?.storage;

  @override
  sofab.InlineBytes? onBlob(int id, int length) =>
      _blob = sofab.InlineBytes(length);

  @override
  sofab.InlineString? onString(int id, int length) =>
      _string = sofab.InlineString(length);

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) =>
      _ints = sofab.InlineInt64Array(count);

  @override
  sofab.InlineFloat64Array? onFp64Array(int id, int count) =>
      _fp64 = sofab.InlineFloat64Array(count);
}

void main() {
  group('the one-shot buffer is scrubbable the moment decode returns', () {
    test('a delivered blob survives the whole buffer being overwritten', () {
      final input = blobAbc();
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));

      input.fillRange(0, input.length, 0x5a);
      expect(
        keep.blob,
        orderedEquals([0x61, 0x62, 0x63]),
        reason: 'decode(buffer) must copy into the caller destination (§6.7.1)',
      );
      // And it is the caller's own storage, not a window onto the input.
      expect(keep.blob!.buffer, isNot(same(input.buffer)));
    });

    test('a string survives it too, as bytes and as a String', () {
      final input = stringAbc();
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      expect(keep.string, 'abc');

      input.fillRange(0, input.length, 0x5a);
      expect(keep.stringBytes, orderedEquals([0x61, 0x62, 0x63]));
      expect(keep.string, 'abc');
      expect(keep.stringBytes!.buffer, isNot(same(input.buffer)));
    });

    test('a window onto a larger arena is not aliased either', () {
      final arena = Uint8List(32);
      arena.setRange(8, 13, blobAbc());
      final input = Uint8List.sublistView(arena, 8, 13);
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      arena.fillRange(0, arena.length, 0x5a);
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));
    });

    test('an array survives the buffer being overwritten', () {
      // array_unsigned id 1, count 3, elements 1,2,3 — then an fp64 array.
      final ints = Uint8List.fromList([0x0b, 0x03, 0x01, 0x02, 0x03]);
      final keep = _Keeper();
      expect(sofab.Decoder.decode(ints, keep), sofab.DecodeStatus.complete);
      ints.fillRange(0, ints.length, 0x5a);
      expect(keep.ints, orderedEquals([1, 2, 3]));

      final fp = BytesBuilder(copy: true);
      final enc = sofab.Encoder(fp.add, buffer: Uint8List(64));
      enc.writeFp64Array(1, const [1.5, 2.5]);
      enc.flush();
      final fpBytes = fp.takeBytes();
      final keep2 = _Keeper();
      expect(sofab.Decoder.decode(fpBytes, keep2), sofab.DecodeStatus.complete);
      fpBytes.fillRange(0, fpBytes.length, 0x5a);
      expect(keep2.fp64, orderedEquals([1.5, 2.5]));
    });

    test('a non-Uint8List input is not aliased, and not copied either', () {
      // The contiguous walker needs a `Uint8List`, so this input takes the
      // streaming engine rather than a copy of itself: §6.6 forbids the codec a
      // copy the wire sizes, whichever engine wanted it.
      final input = <int>[0x0a, 0x1b, 0x61, 0x62, 0x63];
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      input[2] = 0x7a;
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));
    });
  });

  group('streaming decode never aliases a fed chunk', () {
    test('a payload arriving whole in one chunk is copied out', () {
      final chunk = blobAbc();
      final keep = _Keeper();
      final dec = sofab.Decoder(keep);
      expect(dec.feed(chunk), sofab.DecodeStatus.complete);
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));

      // §6: the chunk is reusable the moment `feed` returns.
      chunk.fillRange(0, chunk.length, 0x7a);
      expect(
        keep.blob,
        orderedEquals([0x61, 0x62, 0x63]),
        reason: 'Decoder.feed must not hand out a view onto the chunk',
      );
    });

    test('a payload split across chunks is copied out as well', () {
      final all = blobAbc();
      final keep = _Keeper();
      final dec = sofab.Decoder(keep);
      // One reused scratch chunk, refilled per feed — the shape §6 licenses.
      final scratch = Uint8List(2);
      for (var i = 0; i < all.length; i += 2) {
        final n = i + 2 <= all.length ? 2 : 1;
        scratch.setRange(0, n, all, i);
        dec.feed(Uint8List.sublistView(scratch, 0, n));
        scratch.fillRange(0, scratch.length, 0x7a);
      }
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));
    });

    test('a string arriving in chunks reaches the visitor unaliased', () {
      final all = stringAbc();
      final keep = _Keeper();
      final dec = sofab.Decoder(keep);
      for (final b in all) {
        final one = Uint8List.fromList([b]);
        dec.feed(one);
        one[0] = 0x7a;
      }
      expect(keep.string, 'abc');
      expect(keep.stringBytes, orderedEquals([0x61, 0x62, 0x63]));
    });
  });
}
