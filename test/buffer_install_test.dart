import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
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
