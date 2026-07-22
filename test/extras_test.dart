import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Extra coverage for base-class defaults, multi-byte UTF-8 paths, and small
/// API surfaces not exercised by the conformance vectors.
void main() {
  test(
    'bare MessageVisitor defaults read everything and descend sequences',
    () {
      // A plain visitor with all-default (no-op) methods must still traverse a
      // composite message to COMPLETE.
      final bytes = sofab.Encoder.encodeToBytes((e) {
        e.writeUnsigned(0, 1);
        e.writeSigned(1, -1);
        e.writeFp32(2, 1.5);
        e.writeFp64(3, 2.5);
        e.writeString(4, 'x');
        e.writeBlob(5, Uint8List.fromList([1, 2, 3]));
        e.writeUnsignedArray(6, const [1, 2]);
        e.writeSignedArray(7, const [-1, -2]);
        e.writeFp32Array(8, const [1.0, 2.0]);
        e.writeFp64Array(9, const [1.0, 2.0]);
        e.beginSequence(10);
        e.writeUnsigned(0, 42);
        e.endSequence();
      });
      expect(
        sofab.Decoder.decode(bytes, _DefaultVisitor()),
        sofab.DecodeStatus.complete,
      );
    },
  );

  test('multi-byte UTF-8 (2/3/4-byte) round-trips exactly', () {
    // é (2-byte), € (3-byte), 😀 (4-byte surrogate pair).
    const s = 'aé€\u{1F600}z';
    final bytes = sofab.Encoder.encodeToBytes((e) => e.writeString(0, s));
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(bytes, rec), sofab.DecodeStatus.complete);
    expect(rec.events, ['STR:0:$s']);

    // encodeUtf8Strict produces valid UTF-8 for each width.
    expect(sofab.utf8Valid(sofab.encodeUtf8Strict(s)!), isTrue);
    expect(sofab.encodeUtf8Strict('é')!.length, 2);
    expect(sofab.encodeUtf8Strict('€')!.length, 3);
    expect(sofab.encodeUtf8Strict('\u{1F600}')!.length, 4);
  });

  test('Encoder.reset reuses the buffer for a second message', () {
    final buf = Uint8List(64);
    final out = BytesBuilder(copy: true);
    final enc = sofab.Encoder(out.add, buffer: buf);
    enc.writeUnsigned(0, 1);
    enc.flush();
    final first = out.toBytes();
    enc.reset();
    final out2 = BytesBuilder(copy: true);
    final enc2 = sofab.Encoder(out2.add, buffer: buf);
    enc2.writeUnsigned(0, 1);
    enc2.flush();
    expect(bytesToHex(out2.toBytes()), bytesToHex(first));
  });

  test('SofabException.toString mentions code and message', () {
    const ex = sofab.SofabException(sofab.SofabError.bufferFull, 'no room');
    expect(ex.toString(), contains('bufferFull'));
    expect(ex.toString(), contains('no room'));
    expect(ex.code, sofab.SofabError.bufferFull);
  });

  test('encoder rejects opening more than MAX_DEPTH sequences', () {
    expect(
      () => sofab.Encoder.encodeToBytes((e) {
        for (var i = 0; i <= sofab.maxDepth; i++) {
          e.beginSequence(0);
        }
      }),
      throwsA(
        isA<sofab.SofabException>().having(
          (e) => e.code,
          'code',
          sofab.SofabError.invalidMessage,
        ),
      ),
    );
  });

  test('endSequence with no open sequence throws UsageError', () {
    expect(
      () => sofab.Encoder.encodeToBytes((e) => e.endSequence()),
      throwsA(
        isA<sofab.SofabException>().having(
          (e) => e.code,
          'code',
          sofab.SofabError.usageError,
        ),
      ),
    );
  });

  test('feed after a terminal INVALID keeps returning INVALID', () {
    final dec = sofab.Decoder(RecordingVisitor());
    expect(dec.feed(hexToBytes('07')), sofab.DecodeStatus.invalid);
    expect(dec.feed(hexToBytes('0000')), sofab.DecodeStatus.invalid);
  });
}

/// A concrete visitor with no overrides — exercises the base-class defaults.
class _DefaultVisitor extends sofab.MessageVisitor {}
