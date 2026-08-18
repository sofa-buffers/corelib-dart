import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// The layer a schema-bound (generated) consumer builds on: `VisitorBase`,
/// `decodeUtf8Strict`, `utf8Length` and `elementsEqual`.
///
/// None of it is wire-visible — two ports can disagree about whether a skipped
/// string is validated, or about what a list-vs-default comparison says of a
/// `NaN`, and still exchange byte-identical messages. The shared vectors
/// therefore cannot cover any of it, which is what CORELIB_PLAN §7 makes these
/// unit tests mandatory for.
void main() {
  group('VisitorBase · an undeclared id is skipped, not inspected', () {
    // id 0, fixlen/string, length 2, payload C0 80 — the overlong "Modified
    // UTF-8" NUL, invalid per RFC 3629.
    final invalidString = Uint8List.fromList([0x02, 0x12, 0xC0, 0x80]);

    test('the base MessageVisitor validates a materialized string', () {
      // The contrast case: a hand-written visitor reads everything, so this
      // port's always-strict rule fires and the decode is INVALID.
      expect(
        sofab.Decoder.decode(invalidString, _PlainVisitor()),
        sofab.DecodeStatus.invalid,
      );
    });

    test('VisitorBase does not validate a string it does not declare', () {
      // Whether a string may be inspected at all is a schema question
      // (MESSAGE_SPEC §7.3 + CORELIB_PLAN §6.4): an id this scope does not
      // declare is a skipped field and its bytes are jumped over.
      final vis = _NoDestinations();
      expect(
        sofab.Decoder.decode(invalidString, vis),
        sofab.DecodeStatus.complete,
      );
      expect(vis.events, isEmpty);
    });

    test('an override binds its own id and falls through for the rest', () {
      final bytes = sofab.Encoder.encodeToBytes((e) {
        e.writeString(1, 'bound');
        e.writeString(2, 'unbound');
      });
      final vis = _OneStringField();
      expect(sofab.Decoder.decode(bytes, vis), sofab.DecodeStatus.complete);
      expect(vis.value, 'bound');
      expect(vis.invalid, isFalse);
    });

    test('a bound id with invalid UTF-8 is the consumer own INVALID', () {
      // The callbacks return void, so a schema-bound rejection is recorded on
      // the consumer's sticky flag; the corelib itself sees nothing wrong.
      final vis = _OneStringField();
      expect(
        sofab.Decoder.decode(
          Uint8List.fromList([0x0A, 0x12, 0xC0, 0x80]), // id 1, same payload
          vis,
        ),
        sofab.DecodeStatus.complete,
      );
      expect(vis.value, isNull);
      expect(vis.invalid, isTrue);
    });

    test('a sequence is skipped whole, children and grandchildren', () {
      final bytes = sofab.Encoder.encodeToBytes((e) {
        e.writeUnsigned(0, 7);
        e.beginSequenceLazy(1);
        e.writeUnsigned(0, 8);
        e.beginSequenceLazy(1);
        e.writeUnsigned(0, 9);
        e.endSequence();
        e.endSequence();
        e.writeUnsigned(2, 10);
      });
      final vis = _NoDestinations();
      expect(sofab.Decoder.decode(bytes, vis), sofab.DecodeStatus.complete);
      // Only the two leaves of the outer scope; nothing from inside id 1.
      expect(vis.events, ['U:0:7', 'U:2:10']);
    });

    test('a scope that declares one sequence descends only into that one', () {
      final bytes = sofab.Encoder.encodeToBytes((e) {
        e.beginSequenceLazy(1);
        e.writeUnsigned(0, 1);
        e.endSequence();
        e.beginSequenceLazy(2);
        e.writeUnsigned(0, 2);
        e.endSequence();
      });
      final vis = _OneSequenceField();
      expect(sofab.Decoder.decode(bytes, vis), sofab.DecodeStatus.complete);
      expect(vis.child.events, ['U:0:1']);
    });

    test('every non-string leaf keeps its MessageVisitor default', () {
      final bytes = sofab.Encoder.encodeToBytes((e) {
        e.writeUnsigned(0, 1);
        e.writeSigned(1, -1);
        e.writeFp64(2, 2.5);
        e.writeBlob(3, Uint8List.fromList([1, 2, 3]));
        e.writeUnsignedArray(4, const [1, 2]);
      });
      expect(
        sofab.Decoder.decode(bytes, _NoDestinations()),
        sofab.DecodeStatus.complete,
      );
    });
  });

  group('decodeUtf8Strict', () {
    test('ASCII, including the empty payload and an embedded NUL', () {
      expect(sofab.decodeUtf8Strict(Uint8List(0)), '');
      expect(
        sofab.decodeUtf8Strict(Uint8List.fromList('sofab'.codeUnits)),
        'sofab',
      );
      expect(
        sofab.decodeUtf8Strict(Uint8List.fromList([0x61, 0x00, 0x62])),
        'a\u0000b',
      );
    });

    test('2-, 3- and 4-byte sequences transcode exactly', () {
      const s = 'aé€\u{1F600}z';
      final bytes = sofab.encodeUtf8Strict(s)!;
      expect(sofab.decodeUtf8Strict(bytes), s);
    });

    test('an ASCII prefix does not hide an invalid tail', () {
      // The scan resyncs at the first non-ASCII byte, which is only legal
      // because every byte before it is a complete sequence on its own.
      expect(
        sofab.decodeUtf8Strict(Uint8List.fromList([0x61, 0x62, 0xC0, 0x80])),
        isNull,
      );
      expect(
        sofab.decodeUtf8Strict(Uint8List.fromList([0x61, 0xC3, 0xA9, 0x62])),
        'aéb',
      );
    });

    test('it agrees with utf8Valid on every malformed shape', () {
      const cases = <List<int>>[
        [0x80], // stray continuation
        [0xC0, 0x80], // overlong NUL
        [0xC1, 0xBF], // overlong
        [0xE0, 0x80, 0xAF], // overlong 3-byte
        [0xED, 0xA0, 0x80], // surrogate U+D800
        [0xF0, 0x8F, 0xBF, 0xBF], // overlong 4-byte
        [0xF4, 0x90, 0x80, 0x80], // > U+10FFFF
        [0xF5, 0x80, 0x80, 0x80], // undefined lead
        [0xE2, 0x82], // truncated 3-byte
        [0xC3], // truncated 2-byte
        [0x61, 0x00, 0x62], // valid
        [0xC3, 0xA9], // valid
        [0xF0, 0x9F, 0x98, 0x80], // valid
        [], // valid
      ];
      for (final c in cases) {
        final bytes = Uint8List.fromList(c);
        expect(
          sofab.decodeUtf8Strict(bytes) != null,
          sofab.utf8Valid(bytes),
          reason: 'disagreement on $c',
        );
      }
    });

    test('it is the same verdict the default string path reaches', () {
      // Same bytes, same answer, whether a hand-written visitor lets the
      // default onStringBytes run or a generated arm calls this directly.
      for (final payload in <List<int>>[
        [0x61],
        [0xC3, 0xA9],
        [0xC0, 0x80],
        [0xED, 0xA0, 0x80],
      ]) {
        final msg = Uint8List.fromList([
          0x02, // id 0, fixlen
          (payload.length << 3) | 2, // length, subtype string
          ...payload,
        ]);
        final expected = sofab.decodeUtf8Strict(Uint8List.fromList(payload));
        final vis = _PlainVisitor();
        final status = sofab.Decoder.decode(msg, vis);
        if (expected == null) {
          expect(status, sofab.DecodeStatus.invalid);
        } else {
          expect(status, sofab.DecodeStatus.complete);
          expect(vis.strings, [expected]);
        }
      }
    });
  });

  group('utf8Length', () {
    test('it is exactly what encodeUtf8Strict produces', () {
      const strings = <String>[
        '',
        'sofab',
        'a\u0000b',
        'é', // 2 bytes
        '€', // 3 bytes
        '\u{1F600}', // 4 bytes, surrogate pair
        'aé€\u{1F600}z',
        '\u007f\u07ff\u0800\uffff', // both sides of every boundary
      ];
      for (final s in strings) {
        expect(
          sofab.utf8Length(s),
          sofab.encodeUtf8Strict(s)!.length,
          reason: 'length of ${s.codeUnits}',
        );
      }
    });

    test('a surrogate pair counts 4, not 3 + 3', () {
      expect('\u{1F600}'.length, 2); // two code units...
      expect(sofab.utf8Length('\u{1F600}'), 4); // ...one 4-byte code point
    });

    test('an unpaired surrogate is measured, not rejected', () {
      // Only the encoder judges encodability; this answers "how large".
      const lone = '\ud800';
      expect(sofab.encodeUtf8Strict(lone), isNull);
      expect(sofab.utf8Length(lone), 3);
      expect(sofab.utf8Length('a\udc00'), 4); // lone low surrogate, 1 + 3
      expect(sofab.utf8Length('\ud800a'), 4); // high surrogate, no pair
    });
  });

  group('elementsEqual', () {
    test('length, order and identity', () {
      expect(sofab.elementsEqual<int>(const [], const []), isTrue);
      expect(sofab.elementsEqual<int>(const [1, 2], const [1, 2]), isTrue);
      expect(sofab.elementsEqual<int>(const [1, 2], const [1, 2, 3]), isFalse);
      expect(sofab.elementsEqual<int>(const [1, 2], const [2, 1]), isFalse);
      final same = <int>[1, 2, 3];
      expect(sofab.elementsEqual(same, same), isTrue);
    });

    test('it walks typed lists too', () {
      final typed = Int64List.fromList([10, 20]);
      expect(sofab.elementsEqual<int>(typed, const [10, 20]), isTrue);
      expect(sofab.elementsEqual<int>(typed, const [10, 21]), isFalse);
      expect(
        sofab.elementsEqual<double>(Float64List.fromList([1.5, 2.5]), const [
          1.5,
          2.5,
        ]),
        isTrue,
      );
    });

    test('strings compare by value', () {
      final built = StringBuffer('so')..write('fab');
      expect(
        sofab.elementsEqual(<String>[built.toString()], const ['sofab']),
        isTrue,
      );
    });

    test('IEEE-754: NaN is never equal, -0.0 equals 0.0', () {
      // Both follow from `==` on double, and both decide whether a field equal
      // to its declared default is written out.
      expect(
        sofab.elementsEqual(<double>[double.nan], <double>[double.nan]),
        isFalse,
      );
      expect(sofab.elementsEqual(<double>[-0.0], const <double>[0.0]), isTrue);
    });
  });
}

/// A hand-written visitor: every default intact, so strings are validated and
/// sequences descended.
class _PlainVisitor extends sofab.MessageVisitor {
  final List<String> strings = [];

  @override
  void onString(int id, String value) => strings.add(value);
}

/// A generated scope that declares nothing: every id skips.
class _NoDestinations extends sofab.VisitorBase {
  final List<String> events = [];

  @override
  void onUnsigned(int id, int value) => events.add('U:$id:$value');

  @override
  void onString(int id, String value) => events.add('S:$id:$value');
}

/// A generated scope with one string destination, at id 1.
class _OneStringField extends sofab.VisitorBase {
  String? value;
  bool invalid = false;

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (id != 1) return; // falls through to the base's skip
    final s = sofab.decodeUtf8Strict(bytes);
    if (s == null) {
      invalid = true;
      return;
    }
    value = s;
  }
}

/// A generated scope with one sequence destination, at id 1.
class _OneSequenceField extends sofab.VisitorBase {
  final _NoDestinations child = _NoDestinations();

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => id == 1 ? child : null;
}
