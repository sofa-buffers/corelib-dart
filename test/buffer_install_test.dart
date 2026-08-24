import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The payload every test below encodes: long enough to fill a 24-byte buffer
/// several times over, with a `blob` run that spans buffers so the
/// divisible-run path is exercised too (CORELIB_PLAN §7.2 item 4).
void _build(sofab.Encoder e) {
  for (var i = 0; i < 12; i++) {
    e.writeUnsigned(i, 0x1122334455);
  }
  e.writeBlob(12, Uint8List.fromList(List<int>.generate(70, (i) => i & 0xFF)));
  e.writeString(13, 'the payload outruns the buffer several times over');
}

/// Header room a taking sink re-arms on every installation, pre-filled with a
/// marker the encoder must never overwrite.
const int _reserve = 4;
const int _marker = 0xAA;

void main() {
  final oneShot = sofab.Encoder.encodeToBytes(_build);

  group('CORELIB_PLAN §5.1 buffer handover', () {
    test('an installation from inside the sink keeps its own start offset', () {
      // A taking sink: it hands the buffer on (here: keeps it) and installs a
      // *different* replacement, re-arming `_reserve` bytes of framing-header
      // room in every flushed unit.
      final packets = <Uint8List>[];
      late sofab.Encoder enc;

      Uint8List fresh() {
        final b = Uint8List(24)..fillRange(0, _reserve, _marker);
        return b;
      }

      enc = sofab.Encoder(
        (chunk) {
          packets.add(Uint8List.fromList(chunk));
          enc.installBuffer(fresh(), offset: _reserve);
        },
        buffer: fresh(),
        offset: _reserve,
      );
      _build(enc);
      enc.flush();

      // Every packet is a payload run only — the reservation held each time,
      // so no packet may exceed `24 - _reserve` bytes.
      expect(packets.length, greaterThan(3));
      for (final p in packets) {
        expect(
          p.length,
          lessThanOrEqualTo(24 - _reserve),
          reason:
              'a packet longer than the payload room means the '
              'installation lost its offset and overwrote header room',
        );
      }
      expect(
        bytesToHex(_concat(packets)),
        bytesToHex(oneShot),
        reason: 'the concatenated output must equal the one-shot encoding',
      );
    });

    test('the reserved prefix of every installed buffer is untouched', () {
      final buffers = <Uint8List>[];
      late sofab.Encoder enc;

      Uint8List fresh() {
        final b = Uint8List(24)..fillRange(0, _reserve, _marker);
        buffers.add(b);
        return b;
      }

      enc = sofab.Encoder(
        (chunk) => enc.installBuffer(fresh(), offset: _reserve),
        buffer: fresh(),
        offset: _reserve,
      );
      _build(enc);
      enc.flush();

      expect(buffers.length, greaterThan(3));
      for (final b in buffers) {
        expect(
          b.sublist(0, _reserve),
          List<int>.filled(_reserve, _marker),
          reason: 'the encoder wrote over the reserved framing header',
        );
      }
    });

    test('re-installing the *same* buffer re-arms the reservation', () {
      // §5.1: "Passing the same buffer to buffer-set is a new installation like
      // any other" — that is how a sink gets fresh header room per packet.
      final buf = Uint8List(24)..fillRange(0, _reserve, _marker);
      final packets = <Uint8List>[];
      late sofab.Encoder enc;
      enc = sofab.Encoder(
        (chunk) {
          packets.add(Uint8List.fromList(chunk));
          enc.installBuffer(buf, offset: _reserve);
        },
        buffer: buf,
        offset: _reserve,
      );
      _build(enc);
      enc.flush();

      for (final p in packets) {
        expect(p.length, lessThanOrEqualTo(24 - _reserve));
      }
      expect(buf.sublist(0, _reserve), List<int>.filled(_reserve, _marker));
      expect(bytesToHex(_concat(packets)), bytesToHex(oneShot));
    });

    test('a taking sink that scrubs the buffer it was handed', () {
      // §7.2 item 4: the zero-copy handover. The sink copies the chunk out,
      // then fills the buffer it was given with a pattern before returning — an
      // encoder that kept writing into it would show the pattern in the output.
      final out = <Uint8List>[];
      late sofab.Encoder enc;
      var handed = Uint8List(24);
      enc = sofab.Encoder(
        (chunk) {
          out.add(Uint8List.fromList(chunk));
          handed.fillRange(0, handed.length, 0x5A);
          handed = Uint8List(24);
          enc.installBuffer(handed, offset: _reserve);
        },
        buffer: handed,
        offset: _reserve,
      );
      _build(enc);
      enc.flush();
      expect(bytesToHex(_concat(out)), bytesToHex(oneShot));
    });

    test('a copying sink that returns without installing resumes at 0', () {
      // The other half of the returning-callback contract: a bare return means
      // "copied", the active buffer stays active and the cursor resumes at 0 —
      // the constructor's offset is consumed by its own installation only.
      final buf = Uint8List(24);
      final packets = <Uint8List>[];
      final enc = sofab.Encoder(
        (chunk) => packets.add(Uint8List.fromList(chunk)),
        buffer: buf,
        offset: _reserve,
      );
      _build(enc);
      enc.flush();

      expect(bytesToHex(_concat(packets)), bytesToHex(oneShot));
      // Only the first packet is shortened by the reservation; every later one
      // may use the whole buffer.
      expect(packets.first.length, lessThanOrEqualTo(24 - _reserve));
      expect(packets.any((p) => p.length > 24 - _reserve), isTrue);
    });
  });

  // A buffer handed over *without* a flush sink: no flush can occur, so the
  // buffer either holds the whole message or reports buffer-full — it must
  // never drop what it could not write (CORELIB_PLAN §5.1, "Required
  // capabilities" bullet 1 and the MUST NOT on partial output).
  group('CORELIB_PLAN §5.1 sink-less buffer', () {
    test('a message that fits encodes into the caller buffer, byte-exact', () {
      final buf = Uint8List(oneShot.length);
      final enc = sofab.Encoder.overBuffer(buf);
      _build(enc);
      enc.flush();
      expect(bytesToHex(enc.written), bytesToHex(oneShot));
      expect(enc.pending, oneShot.length);
      // `flush()` has nowhere to drain to: the bytes stay in the buffer and a
      // second read returns the same message, not an empty one.
      enc.flush();
      expect(bytesToHex(enc.written), bytesToHex(oneShot));
    });

    test('a buffer one byte short reports buffer-full, never truncates', () {
      final buf = Uint8List(oneShot.length - 1);
      final enc = sofab.Encoder.overBuffer(buf);
      expect(
        () {
          _build(enc);
          enc.flush();
        },
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.bufferFull,
          ),
        ),
      );
    });

    test('the issue repro: a 4-byte buffer cannot swallow a 10-byte varint', () {
      // Before the fix the only way to hand over a buffer was with a sink, and
      // a no-op sink discarded every byte that did not fit — partial output
      // reported as success.
      final enc = sofab.Encoder.overBuffer(Uint8List(4));
      expect(
        () => enc.writeUnsigned(1, 0x1122334455667788),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.bufferFull,
          ),
        ),
      );
    });

    test('no minimum applies: a two-byte message fits a two-byte buffer', () {
      // §5.1: "a message that encodes to two bytes may be encoded into a
      // two-byte buffer on any port, whatever that port declares" — the
      // converse half of the §7.2 item-4 minimum test.
      final buf = Uint8List(2);
      final enc = sofab.Encoder.overBuffer(buf);
      enc.writeUnsigned(0, 127);
      enc.flush();
      expect(bytesToHex(enc.written), '007f');
      // …and the byte after it does not fit.
      expect(
        () => enc.writeUnsigned(0, 1),
        throwsA(isA<sofab.SofabException>()),
      );
    });

    test('every write kind reports buffer-full rather than dropping bytes', () {
      final cases = <String, void Function(sofab.Encoder)>{
        'blob': (e) => e.writeBlob(1, Uint8List(32)),
        'string': (e) => e.writeString(1, 'a string longer than the buffer'),
        'fp64': (e) => e.writeFp64(1, 3.5),
        'fp32 array': (e) => e.writeFp32Array(1, Float32List(8)),
        'fp64 array': (e) => e.writeFp64Array(1, Float64List(8)),
        'unsigned array': (e) => e.writeUnsignedArray(1, List.filled(8, -1)),
        'signed array': (e) => e.writeSignedArray(1, List.filled(8, -1 << 62)),
        'sequence end': (e) {
          e.writeUnsigned(0, 0x7F);
          e.endSequenceKeep();
        },
      };
      cases.forEach((what, write) {
        final enc = sofab.Encoder.overBuffer(Uint8List(2));
        expect(
          () => write(enc),
          throwsA(isA<sofab.SofabException>()),
          reason: '$what silently discarded output',
        );
      });
    });

    test('the start offset reserves header room the encoder never writes', () {
      final buf = Uint8List(_reserve + oneShot.length)
        ..fillRange(0, _reserve, _marker);
      final enc = sofab.Encoder.overBuffer(buf, offset: _reserve);
      _build(enc);
      enc.flush();
      expect(buf.sublist(0, _reserve), List<int>.filled(_reserve, _marker));
      expect(bytesToHex(enc.written), bytesToHex(oneShot));
      expect(
        bytesToHex(buf.sublist(_reserve)),
        bytesToHex(oneShot),
        reason: 'the message must start at the installation offset',
      );
    });

    test('an out-of-range offset is rejected at handover', () {
      expect(
        () => sofab.Encoder.overBuffer(Uint8List(4), offset: 5),
        throwsA(
          isA<sofab.SofabException>().having(
            (e) => e.code,
            'code',
            sofab.SofabError.invalidArgument,
          ),
        ),
      );
      expect(
        () => sofab.Encoder.overBuffer(Uint8List(4), offset: -1),
        throwsA(isA<sofab.SofabException>()),
      );
    });

    test('installBuffer works sink-less: the caller takes the message out', () {
      // The caller drives the handover itself: encode, take the bytes, install
      // the next buffer. `written` is the extent of the current installation.
      final first = Uint8List(2);
      final enc = sofab.Encoder.overBuffer(first);
      enc.writeUnsigned(0, 127);
      expect(bytesToHex(enc.written), '007f');
      final second = Uint8List(8)..fillRange(0, 2, _marker);
      enc.installBuffer(second, offset: 2);
      enc.writeUnsigned(1, 1);
      enc.flush();
      expect(bytesToHex(enc.written), '0801');
      expect(second.sublist(0, 2), [_marker, _marker]);
      expect(bytesToHex(first), '007f', reason: 'the taken buffer is intact');
    });

    test('reset rewinds a sink-less encoder for the next message', () {
      final buf = Uint8List(4);
      final enc = sofab.Encoder.overBuffer(buf);
      enc.writeUnsigned(0, 127);
      enc.flush();
      expect(bytesToHex(enc.written), '007f');
      enc.reset();
      enc.writeUnsigned(1, 1);
      enc.flush();
      expect(bytesToHex(enc.written), '0801');
    });
  });
}

Uint8List _concat(List<Uint8List> parts) {
  final n = parts.fold<int>(0, (a, p) => a + p.length);
  final out = Uint8List(n);
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}
