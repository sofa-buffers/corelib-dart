import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The payload every streaming test below encodes: several varint fields plus a
/// `blob` and a `string` run far longer than the buffer, so the divisible-run
/// path is exercised whatever the declared minimum is (CORELIB_PLAN §7.2
/// item 4).
void _build(sofab.Encoder e) {
  for (var i = 0; i < 8; i++) {
    e.writeUnsigned(i, 0x1122334455667788);
  }
  e.writeBlob(8, Uint8List.fromList(List<int>.generate(70, (i) => i & 0xFF)));
  e.writeString(9, 'the payload outruns the buffer several times over');
  e.beginSequenceLazy(10);
  e.writeSigned(0, -12345);
  e.writeFp64(1, 3.5);
  e.endSequence();
}

/// Header room a caller reserves at the front of its buffer.
const int _reserve = 4;
const int _marker = 0xAA;

void main() {
  final oneShot = sofab.Encoder.encodeToBytes(_build);

  group('CORELIB_PLAN §5.1 MIN_OUTPUT_BUFFER', () {
    test('the constant is declared, exported and within the §5.1 ceiling', () {
      expect(sofab.minOutputBuffer, greaterThanOrEqualTo(1));
      expect(
        sofab.minOutputBuffer,
        lessThanOrEqualTo(20),
        reason: 'a declaration MUST NOT exceed 20 (§5.1)',
      );
      // This port splits every atomic unit, so the declaration is the floor the
      // spec reserves for that case.
      expect(sofab.minOutputBuffer, 1);
    });

    // §7.2 item 4, first bullet: the encode test runs at *exactly* the declared
    // minimum — the size that proves the constant is real.
    test('a buffer of exactly the minimum streams byte-identical output', () {
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(
        out.add,
        buffer: Uint8List(sofab.minOutputBuffer),
      );
      _build(enc);
      enc.flush();
      expect(bytesToHex(out.toBytes()), bytesToHex(oneShot));
    });

    test('the minimum still holds with a start offset reserved', () {
      // `buflen - offset == minOutputBuffer` is the tightest accepted streaming
      // handover. The sink re-arms the reservation on every flush, so the
      // encoder never gets more room than the minimum for the whole message.
      final out = BytesBuilder(copy: true);
      final buf = Uint8List(_reserve + sofab.minOutputBuffer)
        ..fillRange(0, _reserve, _marker);
      late sofab.Encoder enc;
      enc = sofab.Encoder(
        (chunk) {
          out.add(chunk);
          enc.installBuffer(buf, offset: _reserve);
        },
        buffer: buf,
        offset: _reserve,
      );
      _build(enc);
      enc.flush();
      expect(bytesToHex(out.toBytes()), bytesToHex(oneShot));
      expect(
        buf.sublist(0, _reserve),
        List<int>.filled(_reserve, _marker),
        reason: 'the reserved framing header was written over',
      );
    });

    // §7.2 item 4, second bullet: one byte short of the minimum is rejected
    // *where the buffer is handed over*, by the same mechanism as an
    // out-of-range offset — never partway through a message.
    test('a sink-installed buffer one byte short is rejected at handover', () {
      expect(
        () =>
            sofab.Encoder((_) {}, buffer: Uint8List(sofab.minOutputBuffer - 1)),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      expect(
        () => sofab.Encoder((_) {}, bufferSize: sofab.minOutputBuffer - 1),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
    });

    test('the shortfall is measured after the start offset', () {
      // `buflen - offset` is what binds: a roomy buffer whose offset eats all
      // but `minOutputBuffer - 1` bytes is just as short.
      final buf = Uint8List(64);
      expect(
        () => sofab.Encoder(
          (_) {},
          buffer: buf,
          offset: buf.length - (sofab.minOutputBuffer - 1),
        ),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      // Exactly the minimum after the offset is accepted and works.
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(
        out.add,
        buffer: buf,
        offset: buf.length - sofab.minOutputBuffer,
      );
      enc.writeUnsigned(0, 127);
      enc.flush();
      expect(bytesToHex(out.toBytes()), '007f');
    });

    test('a mid-stream buffer-set below the minimum is rejected there', () {
      // §5.1: the minimum binds "at installation and at every mid-stream
      // buffer-set" — and the encoder that rejects it must not have written
      // anything into the caller's short buffer first.
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(out.add, bufferSize: 32);
      enc.writeUnsigned(0, 127);
      final short = Uint8List(sofab.minOutputBuffer - 1);
      expect(
        () => enc.installBuffer(short),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      final roomy = Uint8List(8);
      expect(
        () => enc.installBuffer(roomy, offset: roomy.length),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      expect(
        () => enc.installBuffer(roomy, offset: -1),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      // The rejected installations changed nothing: the encoder still holds the
      // byte it wrote into the original buffer and finishes the message there.
      enc.flush();
      expect(bytesToHex(out.toBytes()), '007f');
    });

    test('a rejected installation from inside the sink fails there', () {
      // The taking-sink shape: an installation that is too small must fail in
      // the callback, not leave the encoder writing into memory it gave away.
      late sofab.Encoder enc;
      enc = sofab.Encoder(
        (_) => enc.installBuffer(Uint8List(sofab.minOutputBuffer - 1)),
        bufferSize: 4,
      );
      expect(
        () {
          _build(enc);
          enc.flush();
        },
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
    });

    // The converse half of §7.2 item 4: the minimum is a *streaming* constant
    // and must not become a floor on the sink-less path.
    test('the same short buffer without a sink is accepted', () {
      final buf = Uint8List(sofab.minOutputBuffer - 1);
      final enc = sofab.Encoder.overBuffer(buf);
      enc.flush();
      expect(enc.written, isEmpty, reason: 'the empty message fits');
      // …and the caller-supplied buffer with all its room reserved is fine too.
      final reserved = Uint8List(4);
      final enc2 = sofab.Encoder.overBuffer(reserved, offset: reserved.length);
      enc2.flush();
      expect(enc2.written, isEmpty);
      // A message that fits a buffer smaller than the streaming minimum would
      // allow still encodes: two bytes into two bytes.
      final two = sofab.Encoder.overBuffer(Uint8List(2));
      two.writeUnsigned(0, 127);
      two.flush();
      expect(bytesToHex(two.written), '007f');
    });

    test('a sink-less installBuffer is subject to no minimum either', () {
      final enc = sofab.Encoder.overBuffer(Uint8List(2));
      enc.writeUnsigned(0, 127);
      expect(bytesToHex(enc.written), '007f');
      enc.installBuffer(Uint8List(sofab.minOutputBuffer - 1));
      expect(enc.written, isEmpty);
    });
  });
}
