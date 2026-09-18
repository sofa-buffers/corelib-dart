import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// The caller-supplied destination (CORELIB_PLAN §6.6.3, §6.7, §6.3).
///
/// §6.6.3: a callback delivering a materialized aggregate "obliges the codec to
/// build that value, and the only size available to build it from is the
/// wire's". The shape this port implements is the second one the clause names —
/// *"into a destination the caller hands back after being told the announced
/// count, with the codec refusing a destination too short rather than growing
/// it"* — so no wire number sizes anything inside the codec, and every value
/// reaches the caller in the caller's own storage (§6.7's first route).
///
/// Every case runs both decode surfaces: §6.7.1 gives the one-shot path no
/// exemption, so the two must behave identically.
void main() {
  Uint8List enc(void Function(sofab.Encoder) body) =>
      sofab.Encoder.encodeToBytes(body);

  /// Decodes [bytes] into a **fresh** visitor from [make] on each surface and
  /// returns both outcomes plus the visitor each ran with.
  void bothSurfaces(
    Uint8List bytes,
    sofab.MessageVisitor Function() make,
    void Function(sofab.DecodeStatus, sofab.MessageVisitor) check,
  ) {
    final a = make();
    check(sofab.Decoder.decode(bytes, a), a);
    final b = make();
    final dec = sofab.Decoder(b);
    var st = sofab.DecodeStatus.complete;
    for (final byte in bytes) {
      st = dec.feed([byte]);
    }
    check(st, b);
  }

  group('the destination the caller hands back is the one that is filled', () {
    test('a string lands in the caller\'s bytes', () {
      final bytes = enc((e) => e.writeString(1, 'hello'));
      bothSurfaces(bytes, () => _Dest(), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(identical(d.string!.storage, d.handedOut), isTrue);
        expect(d.string!.length, 5);
        expect('${d.string}', 'hello');
      });
    });

    test('an array lands in the caller\'s list', () {
      final bytes = enc((e) => e.writeUnsignedArray(1, const [7, 8, 9]));
      bothSurfaces(bytes, () => _Dest(), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(identical(d.ints!.storage, d.arrayHandedOut), isTrue);
        expect(d.ints!.length, 3);
        expect(d.ints!.toList(), orderedEquals([7, 8, 9]));
      });
    });

    test('an fp64 array lands in the caller\'s list, bit-exact', () {
      final bytes = enc((e) => e.writeFp64Array(1, const [1.5, -2.25]));
      bothSurfaces(bytes, () => _Dest(), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(identical(d.doubles!.storage, d.arrayHandedOut), isTrue);
        expect(d.doubles!.toList(), orderedEquals([1.5, -2.25]));
      });
    });

    test('a destination longer than the payload keeps the extra room', () {
      // The caller hands over a 64-byte scratch for a 5-byte string: the codec
      // writes 5 bytes, sets `length` to 5, and never resizes anything.
      final bytes = enc((e) => e.writeString(1, 'hello'));
      bothSurfaces(bytes, () => _Dest(slack: 64), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(d.string!.capacity, 64);
        expect(d.string!.length, 5);
        expect('${d.string}', 'hello');
      });
    });

    test('an array destination longer than the count is not truncated', () {
      final bytes = enc((e) => e.writeUnsignedArray(1, const [7, 8, 9]));
      bothSurfaces(bytes, () => _Dest(slack: 16), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(d.ints!.capacity, 16);
        expect(d.ints!.length, 3);
        expect(d.ints!.toList(), orderedEquals([7, 8, 9]));
      });
    });

    test('nothing past the announced count is touched', () {
      // The codec writes `count` elements and sets `length`; the rest of the
      // caller's storage is the caller's, and keeps what it held.
      final bytes = enc((e) => e.writeUnsignedArray(1, const [7, 8, 9]));
      final dest = sofab.InlineInt64Array(8)..storage.fillRange(0, 8, -1);
      final v = _Reuse(dest);
      expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.complete);
      expect(dest.storage, orderedEquals([7, 8, 9, -1, -1, -1, -1, -1]));
    });

    test('a destination reused across messages is refilled in place', () {
      // The whole point of a capacity beside a length: storage sized once, to
      // the schema maximum, serves every message — nothing is allocated, and a
      // shorter message simply leaves a shorter `length`.
      final dest = sofab.InlineInt64Array(8);
      final storage = dest.storage;
      final v = _Reuse(dest);
      for (final values in const [
        [1, 2, 3, 4, 5],
        [9],
        <int>[],
        [6, 7],
      ]) {
        final bytes = enc((e) => e.writeUnsignedArray(1, values));
        final dec = sofab.Decoder(v);
        for (final byte in bytes) {
          dec.feed([byte]);
        }
        expect(dest.toList(), values);
        expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.complete);
        expect(dest.toList(), values);
        expect(identical(dest.storage, storage), isTrue);
      }
    });
  });

  group('a destination too short is InvalidArgument (§6.3, third tier)', () {
    // "broke neither [the schema bound nor the receiver cap], but does not fit
    // the destination the caller handed over → InvalidArgument" — the message
    // is well-formed, so this is neither InvalidMessage nor LimitExceeded.
    Matcher throwsInvalidArgument() => throwsA(
      isA<sofab.SofabException>().having(
        (e) => e.code,
        'code',
        sofab.SofabError.invalidArgument,
      ),
    );

    test('a short string destination, on both surfaces', () {
      final bytes = enc((e) => e.writeString(1, 'hello'));
      expect(
        () => sofab.Decoder.decode(bytes, _Short()),
        throwsInvalidArgument(),
      );
      expect(
        () => sofab.Decoder(_Short()).feed(bytes),
        throwsInvalidArgument(),
      );
    });

    test('a short blob destination', () {
      final bytes = enc((e) => e.writeBlob(1, Uint8List(5)));
      expect(
        () => sofab.Decoder.decode(bytes, _Short()),
        throwsInvalidArgument(),
      );
      expect(
        () => sofab.Decoder(_Short()).feed(bytes),
        throwsInvalidArgument(),
      );
    });

    test('a short array destination', () {
      final bytes = enc((e) => e.writeUnsignedArray(1, const [1, 2, 3]));
      expect(
        () => sofab.Decoder.decode(bytes, _Short()),
        throwsInvalidArgument(),
      );
      expect(
        () => sofab.Decoder(_Short()).feed(bytes),
        throwsInvalidArgument(),
      );
    });

    test('a short fp64 array destination', () {
      final bytes = enc((e) => e.writeFp64Array(1, const [1.0, 2.0, 3.0]));
      expect(
        () => sofab.Decoder.decode(bytes, _Short()),
        throwsInvalidArgument(),
      );
      expect(
        () => sofab.Decoder(_Short()).feed(bytes),
        throwsInvalidArgument(),
      );
    });

    test('it is not folded into INVALID or limitExceeded', () {
      // The same bytes decode for a caller that hands over enough room.
      final bytes = enc((e) => e.writeString(1, 'hello'));
      expect(sofab.Decoder.decode(bytes, _Dest()), sofab.DecodeStatus.complete);
    });
  });

  group('declining a destination walks the field', () {
    test('a declined string is neither delivered nor validated', () {
      // The payload is invalid UTF-8 (0xC0 0x80, the overlong NUL): a field
      // that is read would be INVALID, a field that is walked is not
      // (§6.4.5 — "skipped fields are never validated").
      final bytes = Uint8List.fromList([0x0a, 0x12, 0xc0, 0x80]);
      bothSurfaces(bytes, () => _Decline(), (st, v) {
        expect(st, sofab.DecodeStatus.complete);
        expect((v as _Decline).delivered, isEmpty);
      });
    });

    test('a declined array is walked and resync holds', () {
      final bytes = enc((e) {
        e.writeUnsignedArray(1, const [1, 2, 3]);
        e.writeUnsigned(2, 42);
      });
      bothSurfaces(bytes, () => _Decline(), (st, v) {
        expect(st, sofab.DecodeStatus.complete);
        expect((v as _Decline).delivered, ['U:2:42']);
      });
    });

    test('a declined fp64 array is walked and resync holds', () {
      final bytes = enc((e) {
        e.writeFp64Array(1, const [1.0, 2.0]);
        e.writeUnsigned(2, 42);
      });
      bothSurfaces(bytes, () => _Decline(), (st, v) {
        expect(st, sofab.DecodeStatus.complete);
        expect((v as _Decline).delivered, ['U:2:42']);
      });
    });
  });

  test('a zero-length payload still completes without a destination', () {
    final bytes = enc((e) {
      e.writeString(1, '');
      e.writeBlob(2, Uint8List(0));
      e.writeUnsignedArray(3, const []);
    });
    bothSurfaces(bytes, () => _Dest(), (st, v) {
      expect(st, sofab.DecodeStatus.complete);
    });
  });
}

/// Hands out its own storage — `slack` elements/bytes of it where that is more
/// than announced — and remembers what it handed out.
class _Dest extends sofab.MessageVisitor {
  _Dest({this.slack = 0});
  final int slack;

  int _size(int n) => slack > n ? slack : n;

  sofab.InlineString? string;
  sofab.InlineInt64Array? ints;
  sofab.InlineFloat64Array? doubles;

  /// The storage handed out, to check it is the very list that gets filled.
  Uint8List? handedOut;
  TypedData? arrayHandedOut;

  @override
  sofab.InlineString? onString(int id, int length) {
    final d = sofab.InlineString(_size(length));
    handedOut = d.storage;
    return string = d;
  }

  @override
  sofab.InlineBytes? onBlob(int id, int length) =>
      sofab.InlineBytes(_size(length));

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) {
    final d = sofab.InlineInt64Array(_size(count));
    arrayHandedOut = d.storage;
    return ints = d;
  }

  @override
  sofab.InlineFloat64Array? onFp64Array(int id, int count) {
    final d = sofab.InlineFloat64Array(_size(count));
    arrayHandedOut = d.storage;
    return doubles = d;
  }
}

/// Hands the same destination to every unsigned array.
class _Reuse extends sofab.MessageVisitor {
  _Reuse(this.dest);
  final sofab.InlineInt64Array dest;

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) => dest;
}

/// Always one element/byte short of what was announced.
class _Short extends sofab.MessageVisitor {
  static int _less(int n) => n > 0 ? n - 1 : 0;

  @override
  sofab.InlineString? onString(int id, int length) =>
      sofab.InlineString(_less(length));

  @override
  sofab.InlineBytes? onBlob(int id, int length) =>
      sofab.InlineBytes(_less(length));

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) =>
      sofab.InlineInt64Array(_less(count));

  @override
  sofab.InlineFloat64Array? onFp64Array(int id, int count) =>
      sofab.InlineFloat64Array(_less(count));
}

/// Declines every aggregate — the `MessageVisitor` default; scalars still
/// arrive.
class _Decline extends sofab.MessageVisitor {
  final List<String> delivered = [];

  @override
  void onUnsigned(int id, int value) => delivered.add('U:$id:$value');
}
