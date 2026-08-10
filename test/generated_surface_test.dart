// The generated-object layer speaks the closed name set of CORELIB_PLAN §6.1.1
// — `encode()`, `decode(bytes)`, `try_decode(bytes)`, `serialize(ostream)`,
// `deserialize(istream, …)`, `decoder()`, cased the language's way — and a port
// "MUST NOT add a second name for either — no `serialize_to` alongside
// `serialize`, no `from_bytes` alongside `decode`".
//
// `example/person.dart` is this repo's only description of that layer, and the
// README's *Generator* section (§9.5) quotes it, so both are part of the
// surface a user learns from. These tests pin them to the closed set: one half
// compiles against the names (so a rename cannot silently pass), the other
// reads the two documents and rejects any spelling outside the set.

import 'dart:io';
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import '../example/person.dart';

/// §6.1.1's six names, in Dart casing.
const closedNameSet = <String>{
  'encode',
  'decode',
  'tryDecode',
  'serialize',
  'deserialize',
  'decoder',
};

/// The extra spellings §6.1.1 enumerates as forbidden, plus the mirror image of
/// the one this port shipped (`encodeInto` for `serialize`). Matched against
/// *declared member names* and against *call sites on the example's types*,
/// never against free text — `Encoder.encodeToBytes` is an unrelated corelib
/// name that legitimately occurs. `toBytes` is deliberately absent: it is
/// `BytesBuilder`'s, and the streaming snippets call it.
const forbiddenNames = <String>{
  'serializeTo',
  'serialize_to',
  'encodeInto',
  'encode_into',
  'decodeInto',
  'decodeFrom',
  'to_bytes',
  'fromBytes',
  'from_bytes',
  'marshal',
  'unmarshal',
};

/// Names that are legitimately on the example's types but are not §6.1.1
/// surface: plain data fields, the corelib-API `feed` (§6, "anything below this
/// layer … keeps its own names"), the decoder's assembled object, and Dart's
/// mandated `toString`.
const belowTheLayer = <String>{
  'name',
  'age',
  'tags',
  'feed',
  'value',
  'toString',
};

File _repoFile(String relative) {
  final f = File(relative);
  expect(
    f.existsSync(),
    isTrue,
    reason: 'run `dart test` from the package root',
  );
  return f;
}

void main() {
  group('generated-object surface (CORELIB_PLAN §6.1.1)', () {
    // Compiles only if the six names exist with these shapes: a rename back to
    // `serialize()`-as-one-shot or `deserialize(bytes)`-as-static breaks the
    // build rather than the prose.
    test('the closed names are the working surface of the example', () {
      final ada = Person()
        ..name = 'Ada'
        ..age = 36
        ..tags = ['pioneer', 'mathematician'];

      // encode() / decode(bytes) — the one-shot convenience pair.
      final Uint8List bytes = ada.encode();
      final Person back = Person.decode(bytes);
      expect(back.name, 'Ada');
      expect(back.age, 36);
      expect(back.tags, ['pioneer', 'mathematician']);

      // serialize(ostream) — the streaming-out half, over a buffer far smaller
      // than the message, and byte-identical to the one-shot path.
      final collected = BytesBuilder(copy: true);
      final enc = sofab.Encoder(collected.add, buffer: Uint8List(4));
      ada.serialize(enc);
      enc.flush();
      expect(collected.toBytes(), bytes);

      // decoder() + deserialize(istream) — the streaming-in half, one byte at a
      // time.
      final dec = Person.decoder();
      var status = sofab.DecodeStatus.incomplete;
      for (final b in bytes) {
        status = dec.feed([b]);
      }
      expect(status, sofab.DecodeStatus.complete);
      expect(dec.value.tags[1], 'mathematician');

      // The `deserialize` hook is usable on its own: bound to an object, it is
      // what the corelib's decoder calls per field.
      final target = Person();
      expect(
        sofab.Decoder(target.deserialize()).feed(bytes),
        sofab.DecodeStatus.complete,
      );
      expect(target.age, 36);
    });

    test('the example declares no name outside the closed set', () {
      final src = _repoFile('example/person.dart').readAsLinesSync();
      // Members of a top-level class are declared at exactly two spaces; the
      // example's private helper classes (`_PersonVisitor`, …) implement
      // corelib visitor hooks and are not part of the generated surface.
      final decl = RegExp(
        r'^  (?=\S)(?:static\s+)?(?:[\w<>,?\s.]+\s+)?([A-Za-z_]\w*)\s*\(',
      );
      const keywords = <String>{
        'if',
        'for',
        'while',
        'switch',
        'return',
        'assert',
      };
      final publicClass = RegExp(r'^class ([A-Za-z]\w*)');
      var inPublicClass = false;
      final declared = <String>{};
      for (final line in src) {
        final c = publicClass.firstMatch(line);
        if (line.isNotEmpty && !line.startsWith(' ')) {
          inPublicClass = c != null;
        }
        if (!inPublicClass) continue;
        final m = decl.firstMatch(line);
        if (m == null) continue;
        final n = m.group(1)!;
        if (n.startsWith('_') || keywords.contains(n)) continue;
        if (n == 'Person' || n == 'PersonDecoder') continue; // constructors
        declared.add(n);
      }

      expect(
        declared,
        isNotEmpty,
        reason: 'the declaration scan found nothing',
      );
      expect(
        declared.intersection(forbiddenNames),
        isEmpty,
        reason: '§6.1.1 closes the name set; these are the spellings it names',
      );
      expect(
        declared.difference(closedNameSet).difference(belowTheLayer),
        isEmpty,
        reason: 'a generated-object method outside §6.1.1',
      );
      // The example is the port's demonstration of the layer, so it has to show
      // both pairs, not just the convenient one.
      expect(
        declared.containsAll(<String>{
          'encode',
          'decode',
          'serialize',
          'deserialize',
          'decoder',
        }),
        isTrue,
        reason: 'the example must demonstrate both §6.1.1 pairs',
      );
    });

    test('the README calls the example only by the closed names', () {
      final readme = _repoFile('README.md').readAsStringSync();

      // Every call on one of the example's identifiers, wherever it appears —
      // the `### Generator` snippet, the memory-handling prose, the bullets.
      final call = RegExp(
        r'\b(?:Person|ada|back|person|dec)\.([A-Za-z_]\w*)\s*\(',
      );
      final called = <String>{
        for (final m in call.allMatches(readme)) m.group(1)!,
      };
      expect(
        called.difference(closedNameSet).difference(belowTheLayer),
        isEmpty,
        reason: 'the README teaches a spelling outside §6.1.1',
      );

      // The bullets advertise the convenience pair by name; §6.1.1 fixes which
      // pair that is (`encode`/`decode`), and `serialize`/`deserialize` are the
      // streaming pair underneath it, not a synonym.
      final advertised = RegExp(
        r'one-line\s+`(\w+)\(\)`\s*/\s*`(\w+)\(\)`',
        multiLine: true,
      );
      final flat = readme.replaceAll('\n', ' ');
      final ads = advertised.allMatches(flat).toList();
      expect(ads, isNotEmpty, reason: 'the README must name the one-shot pair');
      for (final m in ads) {
        expect(
          <String>[m.group(1)!, m.group(2)!],
          <String>['encode', 'decode'],
        );
      }

      for (final bad in forbiddenNames) {
        expect(
          readme.contains(RegExp('[.`]$bad\\b')),
          isFalse,
          reason: '`$bad` is a second name §6.1.1 forbids',
        );
      }
    });
  });
}
