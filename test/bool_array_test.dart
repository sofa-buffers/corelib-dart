import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// A `boolean` array destination — `range: ElemRange.boolean` (CORELIB_PLAN
/// §4.4): every element other than `0` is read as `true` and held as `1`, so
/// what the destination holds after a decode is already the canonical value —
/// element access sees `1`, never the `2` or `2^64-1` the wire carried.
///
/// Each case runs on both decode surfaces, and the streaming one twice: whole
/// (the word-wise bulk run) and one byte per feed (the per-element path),
/// because each surface normalizes in its own place.
void main() {
  // field 0, unsigned array, count 5: 0, 1, 2, 256, 65535.
  final tolerant = _hex('03050001028002ffff03');
  // field 0, unsigned array, count 2: 0, 2^64-1 — a negative Dart int.
  final u64Max = _hex('030200ffffffffffffffffff01');

  for (final surface in _Surface.values) {
    group(surface.name, () {
      test('non-zero elements are held as 1', () {
        final v = _Field(boolean: true);
        expect(surface.decode(tolerant, v), sofab.DecodeStatus.complete);
        expect(v.dest!.toList(), [0, 1, 1, 1, 1]);
      });

      test('an element with bit 63 set is non-zero, not negative', () {
        final v = _Field(boolean: true);
        expect(surface.decode(u64Max, v), sofab.DecodeStatus.complete);
        expect(v.dest!.toList(), [0, 1]);
      });

      test('a long array normalizes every element', () {
        // Long enough that the whole-buffer surfaces take the word-wise run.
        final values = [for (var i = 0; i < 64; i++) i % 3 == 0 ? 0 : i * 1000];
        final bytes = sofab.Encoder.encodeToBytes(
          (e) => e.writeUnsignedArray(0, values),
        );
        final v = _Field(boolean: true);
        expect(surface.decode(bytes, v), sofab.DecodeStatus.complete);
        expect(v.dest!.toList(), [for (final x in values) x == 0 ? 0 : 1]);
      });

      test('a destination that is not boolean keeps the raw values', () {
        final v = _Field(boolean: false);
        expect(surface.decode(tolerant, v), sofab.DecodeStatus.complete);
        expect(v.dest!.toList(), [0, 1, 2, 256, 65535]);
      });

      test('a truncated array holds its decoded prefix as 0/1', () {
        final v = _Field(boolean: true);
        final cut = Uint8List.sublistView(tolerant, 0, tolerant.length - 1);
        expect(surface.decode(cut, v), sofab.DecodeStatus.incomplete);
        final d = v.dest!;
        // Elements 0..3 arrived whole; the fifth did not.
        expect(d.storage.sublist(0, 4), [0, 1, 1, 1]);
      });
    });
  }

  test('IntMatrixSeq hands a boolean matrix boolean rows', () {
    final out = <sofab.InlineInt64Array>[];
    final bytes = sofab.Encoder.encodeToBytes((e) {
      e.beginSequenceLazy(1);
      e.writeUnsignedArray(0, [0, 2, 7]);
      e.writeUnsignedArray(1, [48]);
      e.endSequence();
    });
    final st = sofab.Decoder.decode(
      bytes,
      _Root(
        sofab.IntMatrixSeq(
          out,
          -1,
          false,
          0,
          0,
          rcap: sofab.arrayMax,
          rowCount: -1,
          rowCap: sofab.arrayMax,
          boolean: true,
        ),
      ),
    );
    expect(st, sofab.DecodeStatus.complete);
    expect(out.map((r) => r.toList()).toList(), [
      [0, 1, 1],
      [1],
    ]);
    expect(out.every((r) => r.range == sofab.ElemRange.boolean), isTrue);
  });
}

enum _Surface {
  oneShot,
  streamed,
  byteByByte;

  sofab.DecodeStatus decode(Uint8List bytes, _Field v) {
    switch (this) {
      case _Surface.oneShot:
        return sofab.Decoder.decode(bytes, v);
      case _Surface.streamed:
        return sofab.Decoder(v).feed(bytes);
      case _Surface.byteByByte:
        final dec = sofab.Decoder(v);
        var st = dec.feed(const <int>[]);
        for (final b in bytes) {
          st = dec.feed(Uint8List.fromList([b]));
        }
        return st;
    }
  }
}

/// One unsigned array at id 0, into a destination sized to the count.
class _Field extends sofab.MessageVisitor {
  _Field({required this.boolean});

  final bool boolean;
  sofab.InlineInt64Array? dest;

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) {
    if (id != 0) return null;
    return dest = sofab.InlineInt64Array(
      count,
      range: boolean ? sofab.ElemRange.boolean : null,
    );
  }
}

class _Root extends sofab.MessageVisitor {
  _Root(this.child);
  final sofab.MessageVisitor child;

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => id == 1 ? child : null;
}

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
