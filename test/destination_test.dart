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
        expect(d.handedOut, isNotNull);
        expect(identical(d.gotBytes, d.handedOut), isTrue);
        expect(d.gotBytes!.sublist(0, 5), orderedEquals('hello'.codeUnits));
        expect(d.total, 5);
      });
    });

    test('an array lands in the caller\'s list', () {
      final bytes = enc((e) => e.writeUnsignedArray(1, const [7, 8, 9]));
      bothSurfaces(bytes, () => _Dest(), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(identical(d.gotArray, d.arrayHandedOut), isTrue);
        expect(
          (d.gotArray as Int64List).sublist(0, 3),
          orderedEquals([7, 8, 9]),
        );
        expect(d.count, 3);
      });
    });

    test('an fp64 array lands in the caller\'s list, bit-exact', () {
      final bytes = enc((e) => e.writeFp64Array(1, const [1.5, -2.25]));
      bothSurfaces(bytes, () => _Dest(), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(identical(d.gotArray, d.arrayHandedOut), isTrue);
        expect(
          (d.gotArray as Float64List).sublist(0, 2),
          orderedEquals([1.5, -2.25]),
        );
      });
    });

    test('a destination longer than the payload keeps the extra room', () {
      // The caller hands over a 64-byte scratch for a 5-byte string: the codec
      // writes 5 bytes and reports 5, and never resizes anything.
      final bytes = enc((e) => e.writeString(1, 'hello'));
      bothSurfaces(bytes, () => _Dest(slack: 64), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect(d.handedOut!.length, 64);
        expect(d.total, 5);
        expect(d.stringSeen, 'hello');
      });
    });

    test('an array destination longer than the count is not truncated', () {
      final bytes = enc((e) => e.writeUnsignedArray(1, const [7, 8, 9]));
      bothSurfaces(bytes, () => _Dest(slack: 16), (st, v) {
        final d = v as _Dest;
        expect(st, sofab.DecodeStatus.complete);
        expect((d.gotArray as Int64List).length, 16);
        expect(d.count, 3);
        expect(d.arraySeen, orderedEquals([7, 8, 9]));
      });
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

    test('a destination of the wrong element type', () {
      final bytes = enc((e) => e.writeFp64Array(1, const [1.0]));
      expect(
        () => sofab.Decoder.decode(bytes, _WrongType()),
        throwsInvalidArgument(),
      );
      expect(
        () => sofab.Decoder(_WrongType()).feed(bytes),
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

/// Hands out its own storage and remembers what came back.
class _Dest extends sofab.MessageVisitor {
  _Dest({this.slack = 0});
  final int slack;

  Uint8List? handedOut;
  Uint8List? gotBytes;
  int total = -1;
  String? stringSeen;

  TypedData? arrayHandedOut;
  TypedData? gotArray;
  int count = -1;
  List<int>? arraySeen;

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) =>
      handedOut = Uint8List(slack > total ? slack : total);

  @override
  void onBytesDone(int id, int subtype, Uint8List dest, int total) {
    gotBytes = dest;
    this.total = total;
    super.onBytesDone(id, subtype, dest, total);
  }

  @override
  void onString(int id, String value) => stringSeen = value;

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    final n = slack > count ? slack : count;
    switch (kind) {
      case sofab.ArrayKind.unsigned:
      case sofab.ArrayKind.signed:
        return arrayHandedOut = Int64List(n);
      case sofab.ArrayKind.fp32:
        return arrayHandedOut = Float32List(n);
      case sofab.ArrayKind.fp64:
        return arrayHandedOut = Float64List(n);
    }
  }

  @override
  void onArrayDone(int id, sofab.ArrayKind kind, TypedData dest, int count) {
    gotArray = dest;
    this.count = count;
    super.onArrayDone(id, kind, dest, count);
  }

  @override
  void onUnsignedArray(int id, Int64List values) => arraySeen = values.toList();
}

/// Always one element/byte short of what was announced.
class _Short extends sofab.MessageVisitor {
  @override
  Uint8List? onBytesDest(int id, int subtype, int total) =>
      Uint8List(total > 0 ? total - 1 : 0);

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    final n = count > 0 ? count - 1 : 0;
    switch (kind) {
      case sofab.ArrayKind.unsigned:
      case sofab.ArrayKind.signed:
        return Int64List(n);
      case sofab.ArrayKind.fp32:
        return Float32List(n);
      case sofab.ArrayKind.fp64:
        return Float64List(n);
    }
  }
}

/// Hands back a list of the wrong element type.
class _WrongType extends sofab.MessageVisitor {
  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) =>
      Int64List(count);
}

/// Declines every aggregate; scalars still arrive.
class _Decline extends sofab.MessageVisitor {
  final List<String> delivered = [];

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) => null;

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) => null;

  @override
  void onString(int id, String value) => delivered.add('S:$id:$value');

  @override
  void onBlob(int id, Uint8List value) => delivered.add('B:$id');

  @override
  void onUnsigned(int id, int value) => delivered.add('U:$id:$value');

  @override
  void onUnsignedArray(int id, Int64List values) => delivered.add('AU:$id');

  @override
  void onFp64Array(int id, Float64List values) => delivered.add('AF:$id');
}
