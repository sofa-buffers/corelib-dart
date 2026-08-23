// CORELIB_PLAN §9.6 — *Input buffer (decoding)*: a port must state, for the
// **one-shot** `decode(buffer)`, whether decoded `string`/`blob` values are
// zero-copy views into the caller's buffer or copies. For the **streaming**
// `feed(chunk)` there is nothing to choose: §6 requires a fed chunk to be
// reusable the moment `feed` returns.
//
// This port's two surfaces differ, so the two halves below pin them:
//
// * the behaviour half proves what each surface actually does with the bytes —
//   `Decoder.decode` borrows the caller's buffer, `Decoder.feed` never aliases
//   a fed chunk;
// * the documentation half reads the README's `## Memory handling` section and
//   rejects it unless it states both, because a caller who retains a delivered
//   `Uint8List` learns the rule from there and nowhere else.

import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// `blob` field id 1, payload 'abc': header `(1<<3)|2`, `fixlen_word` `(3<<3)|3`.
Uint8List blobAbc() =>
    Uint8List.fromList([0x0a, 0x1b, 0x61, 0x62, 0x63]); // 'abc'

/// `string` field id 1, payload 'abc': `fixlen_word` `(3<<3)|2`.
Uint8List stringAbc() => Uint8List.fromList([0x0a, 0x1a, 0x61, 0x62, 0x63]);

/// Retains exactly what the decoder hands over — no copy — which is what a
/// caller does when the README tells it the value outlives the callback.
class _Keeper extends sofab.MessageVisitor {
  Uint8List? blob;
  Uint8List? stringBytes;
  String? string;

  @override
  void onBlob(int id, Uint8List value) => blob = value;

  @override
  void onStringBytes(int id, Uint8List bytes) {
    stringBytes = bytes;
    super.onStringBytes(id, bytes);
  }

  @override
  void onString(int id, String value) => string = value;
}

void main() {
  group('one-shot decode borrows the caller\'s buffer', () {
    test('a delivered blob is a view into the input, not a copy', () {
      final input = blobAbc();
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));

      // The caller reuses its own buffer. A copy would be unaffected; a view
      // moves with the bytes, and that is the contract §9.6 wants stated.
      input[2] = 0x7a; // 'z'
      expect(
        keep.blob,
        orderedEquals([0x7a, 0x62, 0x63]),
        reason: 'Decoder.decode must hand onBlob a zero-copy view',
      );
      // A view, positioned on the payload: the same backing store, offset past
      // the two header bytes.
      expect(keep.blob!.offsetInBytes, input.offsetInBytes + 2);
    });

    test('onStringBytes is a view too; onString is a fresh String', () {
      final input = stringAbc();
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      expect(keep.string, 'abc');
      expect(keep.stringBytes!.offsetInBytes, input.offsetInBytes + 2);

      input[2] = 0x7a;
      expect(keep.stringBytes, orderedEquals([0x7a, 0x62, 0x63]));
      // Transcoding always copies, so the String is immune by construction.
      expect(keep.string, 'abc');
    });

    test(
      'a view stays inside the caller-supplied window of a larger buffer',
      () {
        // The input is a window onto a bigger arena: the view must land on the
        // message's bytes, not on the arena's origin.
        final arena = Uint8List(32);
        arena.setRange(8, 13, blobAbc());
        final input = Uint8List.sublistView(arena, 8, 13);
        final keep = _Keeper();
        expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
        expect(keep.blob, orderedEquals([0x61, 0x62, 0x63]));
        arena[10] = 0x7a;
        expect(keep.blob, orderedEquals([0x7a, 0x62, 0x63]));
      },
    );

    test('a non-Uint8List input is copied once, so it is not aliased', () {
      final input = <int>[0x0a, 0x1b, 0x61, 0x62, 0x63];
      final keep = _Keeper();
      expect(sofab.Decoder.decode(input, keep), sofab.DecodeStatus.complete);
      input[2] = 0x7a;
      expect(
        keep.blob,
        orderedEquals([0x61, 0x62, 0x63]),
        reason: 'the plain List<int> is copied into a Uint8List up front',
      );
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
