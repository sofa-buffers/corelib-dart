// The README's Generator example, as code that runs — and a check that the
// README still shows the code `example/person.dart` actually implements.
//
// A hand-written snippet in a Markdown file stops matching the API the moment
// the API moves, and nothing notices until a reader copies it. `example/person.dart`
// is a real file the analyzer and this test see; the mirror check below fails if
// the README's snippet and that file ever disagree about the calls it makes.
// Nothing here asserts what the README *says* — only that the code in it is the
// code that exists, and that the code works.

import 'dart:io';
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import '../example/person.dart';

/// The first ```dart fence inside the named section.
String _dartBlock(String doc, String heading) {
  final i = doc.indexOf(heading);
  expect(i, greaterThan(-1), reason: 'README has no `$heading` section');
  var rest = doc.substring(i);
  final end = rest.indexOf('\n## ', heading.length);
  if (end >= 0) rest = rest.substring(0, end);
  final s = rest.indexOf('```dart');
  expect(s, greaterThan(-1), reason: '`$heading` has no ```dart example');
  rest = rest.substring(s + '```dart'.length);
  final e = rest.indexOf('```');
  expect(e, greaterThan(-1), reason: 'unterminated code fence');
  return rest.substring(0, e);
}

void main() {
  group('the README Generator example', () {
    test('round-trips one-shot, and streams the same bytes', () {
      final ada = Person()
        ..name = 'Ada'
        ..age = 36
        ..tags = ['pioneer', 'mathematician'];

      final bytes = ada.encode();
      final back = Person.decode(bytes);
      expect(back.name, 'Ada');
      expect(back.age, 36);
      expect(back.tags, ['pioneer', 'mathematician']);

      // The streaming pair must produce exactly the one-shot bytes, through a
      // buffer far smaller than the message.
      final out = BytesBuilder();
      final enc = sofab.Encoder(out.add, buffer: Uint8List(4));
      ada.serialize(enc);
      enc.flush();
      expect(out.toBytes(), orderedEquals(bytes));
    });

    test('decodes when fed one byte at a time', () {
      final ada = Person()
        ..name = 'Ada'
        ..age = 36
        ..tags = ['pioneer', 'mathematician'];
      final bytes = ada.encode();

      final dec = Person.decoder();
      for (final b in bytes) {
        dec.feed(Uint8List.fromList([b]));
      }
      final person = dec.value;
      expect(person.name, 'Ada');
      expect(person.age, 36);
      expect(person.tags, ['pioneer', 'mathematician']);
    });

    test('every call it shows exists in example/person.dart', () {
      final readme = File('README.md');
      expect(
        readme.existsSync(),
        isTrue,
        reason: 'run `dart test` from the package root',
      );
      final block = _dartBlock(
        readme.readAsStringSync(),
        '### Generator (generated objects',
      );
      final example = File('example/person.dart').readAsStringSync();

      // The member names the snippet reaches for; each must be declared by the
      // example the README points the reader at.
      const members = [
        'encode()',
        'decode(',
        'serialize(',
        'decoder()',
        'feed(',
        'value',
      ];
      for (final m in members) {
        expect(
          block.contains(m),
          isTrue,
          reason: 'the README snippet no longer shows `$m`',
        );
        expect(
          example.contains(m),
          isTrue,
          reason:
              'example/person.dart does not implement `$m`, '
              'which the README snippet calls',
        );
      }
    });
  });
}
