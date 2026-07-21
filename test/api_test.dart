import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

void main() {
  test('API version is 1', () {
    expect(sofab.apiVersion, 1);
  });

  test('limits & constants match the spec', () {
    expect(sofab.idMax, 2147483647);
    expect(sofab.fixlenMax, 2147483647);
    expect(sofab.arrayMax, 2147483647);
    expect(sofab.maxDepth, 255);
  });

  test('boolean round-trips as unsigned 0/1', () {
    final bytes = sofab.Encoder.encodeToBytes((e) {
      e.writeBool(0, true);
      e.writeBool(1, false);
    });
    // true → 00 01 ; false → 08 00
    expect(bytesToHex(bytes), '00010800');
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(bytes, rec), sofab.DecodeStatus.complete);
    expect(rec.events, ['U:0:1', 'U:1:0']);
  });

  test('full u64 range round-trips via bit pattern', () {
    final bytes = sofab.Encoder.encodeToBytes((e) {
      e.writeUnsigned(0, -1); // 2^64 - 1
      e.writeUnsigned(1, 0x7FFFFFFFFFFFFFFF);
    });
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(bytes, rec), sofab.DecodeStatus.complete);
    expect(rec.events, ['U:0:-1', 'U:1:9223372036854775807']);
  });

  test('encoder field id out of range throws InvalidArgument', () {
    expect(
      () => sofab.Encoder.encodeToBytes((e) => e.writeUnsigned(-1, 0)),
      throwsA(isA<sofab.SofabException>()
          .having((e) => e.code, 'code', sofab.SofabError.invalidArgument)),
    );
    expect(
      () => sofab.Encoder.encodeToBytes(
          (e) => e.writeUnsigned(sofab.idMax + 1, 0)),
      throwsA(isA<sofab.SofabException>()
          .having((e) => e.code, 'code', sofab.SofabError.invalidArgument)),
    );
  });

  test('encoder buffer-full without flush room throws BufferFull', () {
    // A zero-length buffer with a no-op flush cannot hold any byte.
    final enc = sofab.Encoder((_) {}, buffer: Uint8List(0));
    expect(
      () => enc.writeUnsigned(0, 1),
      throwsA(isA<sofab.SofabException>()
          .having((e) => e.code, 'code', sofab.SofabError.bufferFull)),
    );
  });

  test('offset leaves room at the front; message bytes are unchanged', () {
    final withOffset =
        sofab.Encoder.encodeToBytes((e) => e.writeUnsigned(0, 127), offset: 16);
    final withoutOffset =
        sofab.Encoder.encodeToBytes((e) => e.writeUnsigned(0, 127));
    expect(bytesToHex(withOffset), bytesToHex(withoutOffset));
    expect(bytesToHex(withOffset), '007f');
  });

  test('mid-stream buffer swap continues without data loss', () {
    final out = BytesBuilder(copy: true);
    // Two 8-byte buffers, swapped inside the flush callback.
    final buffers = [Uint8List(8), Uint8List(8)];
    var next = 0;
    late sofab.Encoder enc;
    enc = sofab.Encoder((chunk) {
      out.add(chunk);
      enc.installBuffer(buffers[next]);
      next = (next + 1) % 2;
    }, buffer: buffers[0]);
    next = 1;
    for (var i = 0; i < 20; i++) {
      enc.writeUnsigned(i, i);
    }
    enc.flush();
    final oneShot = sofab.Encoder.encodeToBytes((e) {
      for (var i = 0; i < 20; i++) {
        e.writeUnsigned(i, i);
      }
    });
    expect(bytesToHex(out.toBytes()), bytesToHex(oneShot));
  });

  group('receiver-side limits (policy, not INVALID)', () {
    test('array count over maxArrayCount → limitExceeded', () {
      final bytes = sofab.Encoder.encodeToBytes(
          (e) => e.writeUnsignedArray(0, [1, 2, 3, 4, 5]));
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor(),
            limits: const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      // Same bytes decode fine with no configured limit.
      expect(sofab.Decoder.decode(bytes, RecordingVisitor()),
          sofab.DecodeStatus.complete);
    });

    test('string length over maxStringLen → limitExceeded', () {
      final bytes =
          sofab.Encoder.encodeToBytes((e) => e.writeString(0, 'abcdef'));
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor(),
            limits: const sofab.DecoderLimits(maxStringLen: 3)),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('a skipped over-limit field is not policed (limit applies on read)',
        () {
      final bytes = sofab.Encoder.encodeToBytes(
          (e) => e.writeUnsignedArray(7, [1, 2, 3, 4, 5]));
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor(skipIds: {7}),
            limits: const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.complete,
      );
    });
  });

  test('empty sequence and empty arrays are well-formed', () {
    final bytes = sofab.Encoder.encodeToBytes((e) {
      e.beginSequence(0);
      e.endSequence();
      e.writeUnsignedArray(1, const []);
      e.writeFp32Array(2, const []);
    });
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(bytes, rec), sofab.DecodeStatus.complete);
    expect(rec.events, ['SEQ:0', 'END', 'AU:1:', 'AF32:2:']);
  });
}
