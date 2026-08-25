import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// The `string` write path (CORELIB_PLAN §4.6, §5.1, §6.4, §6.6).
///
/// A non-ASCII string's wire length is not known until it has been transcoded,
/// and the `fixlen_word` carrying it goes out first. The encoder therefore
/// transcodes straight into the caller's output buffer behind a reserved word,
/// then writes the word and slides the payload back against it — because the
/// alternative, a transcode buffer, is storage the codec would size from the
/// value it was handed, which §6.6 forbids on any path.
///
/// What that shape has to prove is that the bytes are unchanged by it: for
/// every payload length, for every output-buffer size, and for a string that
/// turns out not to be encodable at all.
void main() {
  /// The reference encoding of one `string` field, built from the primitives:
  /// header varint, `fixlen_word` varint, then the UTF-8 bytes.
  Uint8List reference(int id, String value) {
    final bytes = sofab.encodeUtf8Strict(value)!;
    final out = BytesBuilder(copy: true);
    void varint(int v) {
      var x = v;
      while (x >= 0x80) {
        out.addByte((x & 0x7F) | 0x80);
        x >>>= 7;
      }
      out.addByte(x);
    }

    varint((id << 3) | 2); // wire type fixlen
    varint((bytes.length << 3) | 2); // subtype string
    out.add(bytes);
    return out.takeBytes();
  }

  Uint8List encode(int id, String value, {int buffer = 4096}) {
    final out = BytesBuilder(copy: true);
    final enc = sofab.Encoder(out.add, buffer: Uint8List(buffer));
    enc.writeString(id, value);
    enc.flush();
    return out.takeBytes();
  }

  group('the payload lands where the fixlen_word says, at every width', () {
    // The word is `(byteLength << 3) | 2`, so its varint width changes at
    // byteLength 16, 2048 and 262144 — the boundaries the payload slide has to
    // survive, since the reserved room is always the widest.
    for (final len in const [0, 1, 15, 16, 17, 2047, 2048, 2049, 40000]) {
      test('a $len-byte payload', () {
        // 'ä' is 2 UTF-8 bytes, so an odd length is one 'a' plus 'ä' repeats.
        final value = (len.isOdd ? 'a' : '') + 'ä' * (len ~/ 2);
        expect(sofab.utf8LengthStrict(value), len);
        final got = encode(7, value, buffer: 3 * len + 64);
        expect(got, orderedEquals(reference(7, value)));

        // ...and it decodes back to the same string.
        final rec = _Rec();
        expect(sofab.Decoder.decode(got, rec), sofab.DecodeStatus.complete);
        expect(rec.value, value);
      });
    }
  });

  test('every buffer size produces the same bytes', () {
    const value = 'aä€\u{1d11e}z';
    final want = reference(3, value);
    for (var size = 1; size <= 40; size++) {
      expect(
        encode(3, value, buffer: size),
        orderedEquals(want),
        reason: 'buffer $size',
      );
    }
  });

  test('a two-byte field header is written correctly', () {
    const value = 'ä€';
    expect(encode(130, value), orderedEquals(reference(130, value)));
  });

  test('an unpaired surrogate after a non-ASCII prefix writes nothing', () {
    // Drives the rejection out of the in-buffer transcode, part-way through a
    // payload it has already written bytes for: the cursor and the held-back
    // sequence run must both come back, so closing the frame still drops it.
    final out = BytesBuilder(copy: true);
    final enc = sofab.Encoder(out.add, buffer: Uint8List(256));
    enc.beginSequenceLazy(1);
    expect(
      () => enc.writeString(0, 'ä€${String.fromCharCode(0xD800)}tail'),
      throwsA(
        isA<sofab.SofabException>().having(
          (e) => e.code,
          'code',
          sofab.SofabError.invalidArgument,
        ),
      ),
    );
    enc.endSequence();
    enc.writeUnsigned(2, 7);
    enc.flush();
    // Only the u64 field: the dropped frame left no header behind it.
    expect(out.takeBytes(), orderedEquals([0x10, 0x07]));
  });

  test('a lone low surrogate is rejected in the small-buffer path too', () {
    final out = BytesBuilder(copy: true);
    final enc = sofab.Encoder(out.add, buffer: Uint8List(2));
    expect(
      () => enc.writeString(0, 'ä${String.fromCharCode(0xDC00)}'),
      throwsA(isA<sofab.SofabException>()),
    );
  });

  test('an ASCII string still takes the one-pass path', () {
    const value = 'sofab';
    expect(encode(5, value), orderedEquals(reference(5, value)));
    expect(encode(5, value, buffer: 1), orderedEquals(reference(5, value)));
  });
}

class _Rec extends sofab.MessageVisitor {
  String? value;
  @override
  void onString(int id, String v) => value = v;
}
