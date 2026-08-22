// CORELIB_PLAN §9 — guards README.md's shape *and* the facts the plan obliges
// this port to state.
//
// §9 fixes one README structure for the whole corelib family: "Do not change
// the section ordering and do not invent new top-level sections; that shared
// shape is the point." A reader who knows one port's README navigates any
// other by looking in the same place. Nothing inside the library can notice
// when that shape drifts — an invented top-level section, a missing badge, a
// dropped Usage example — so the check has to read the document.
//
// What it enforces:
//
//   1. §9.1  the centered header block: logo, `# SofaBuffers`, tagline, org
//            link.
//   2. §9.2  the badge block opening the library section carries a CI, a
//            coverage and a Docs badge, in that order, ahead of any prose.
//   3. §9    the `## ` sections are exactly the prescribed list, in order.
//   4. §9.4  no API-documentation section at any heading level; the Docs badge
//            is the only pointer to the generated reference.
//   5. §9.5  the Usage chapter still shows each example the plan lists.
//   6. §9.6  MIN_OUTPUT_BUFFER is stated *inside* the memory chapter — it is
//            the number a caller needs before it can size a streaming buffer,
//            and that chapter is where they go to find out who allocates what,
//            so stating it elsewhere does not reach them.
//   7. §6.5  the raw fp32-bytes path is documented. Dart's only floating type
//            is `double`, so this is a **double-only target**: widening an
//            fp32 sNaN quiets it, and the plan makes the raw-wire-bytes
//            channel mandatory for such a port. A reader who never learns the
//            channel exists writes a bit-inexact round trip.
//   8. §6.1.1 no spelling outside the closed generated-object name set.
//   9.       every in-document link resolves to a heading.
//
// **§6.4 is deliberately NOT checked here.** The strict-UTF-8 knob
// (`SOFAB_STRICT_UTF8`) is required only of *byte-container* string targets.
// A Dart `String` is a Unicode type that cannot hold non-UTF-8 bytes, so §6.4
// puts this port in the "always strict, MAY omit it entirely" class — there is
// no option to document, and demanding one here would demand a lie.

import 'dart:io';

import 'package:test/test.dart';

/// One Markdown ATX heading.
class _Heading {
  const _Heading(this.level, this.text);

  final int level;
  final String text;

  /// The heading slug GitHub links to: lowercased, punctuation dropped,
  /// spaces to hyphens.
  String get anchor {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      if (RegExp(r'[a-z0-9_-]').hasMatch(char)) {
        buffer.write(char);
      } else if (char == ' ') {
        buffer.write('-');
      }
    }
    return buffer.toString();
  }
}

final RegExp _headingLine = RegExp(r'^(#{1,6}) +(.*?)\s*$');

/// The README's lines with fenced code blocks blanked out: a `#` comment
/// inside a ```console block is not a section heading, and Build & test is
/// full of them.
List<String> _prose(String readme) {
  final out = <String>[];
  var fenced = false;
  for (final line in readme.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      fenced = !fenced;
      out.add('');
      continue;
    }
    out.add(fenced ? '' : line);
  }
  return out;
}

List<_Heading> _headings(String readme) {
  final out = <_Heading>[];
  for (final line in _prose(readme)) {
    final match = _headingLine.firstMatch(line);
    if (match != null) {
      out.add(_Heading(match.group(1)!.length, match.group(2)!));
    }
  }
  return out;
}

/// The body of the `## <name>` chapter, up to the next `## `.
String _chapter(String readme, String name) {
  final out = <String>[];
  var inside = false;
  for (final line in _prose(readme)) {
    if (line.startsWith('## ')) {
      if (inside) break;
      inside = line.trimRight() == '## $name';
      continue;
    }
    if (inside) out.add(line);
  }
  return out.join('\n');
}

/// The section list §9 prescribes, in order. Only the first varies per port
/// (`## SofaBuffers <Language> library`). §9.1's `# SofaBuffers` is the
/// document title, and §9.4 forbids an API-documentation chapter — so anything
/// else at `## ` level is invented: demote it to a `###` subsection of the
/// chapter it belongs to instead of adding a row here.
const List<String> _topLevelSections = [
  'SofaBuffers Dart library',
  'Why this design',
  'Usage',
  'Memory handling',
  'Build & test',
  'Benchmarks',
];

/// §9.5's examples. The plan names the use cases; a port words the heading in
/// its own idiom, so each entry is matched as a `### ` heading *prefix*.
const List<String> _usageExamples = [
  'Simple encode',
  'Simple decode',
  'Streaming a message larger than the buffer',
  'OStream',
  'IStream',
  'Generator',
];

/// §6.1.1 closes the generated-object layer to encode / decode / try_decode /
/// serialize / deserialize / decoder. Teaching one of these spellings sends a
/// reader looking for a surface sofabgen does not emit, as effectively as
/// emitting it would.
final RegExp _forbiddenNames = RegExp(
  r'\b(marshal|unmarshal|serialize_to|to_bytes|from_bytes|decode_from|'
  r'decode_into)\b',
  caseSensitive: false,
);

void main() {
  late String readme;

  setUpAll(() {
    final file = File('README.md');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run `dart test` from the package root (README.md not found)',
    );
    readme = file.readAsStringSync();
  });

  test('§9.1 the centered header block is intact', () {
    expect(
      readme,
      contains('<p align="center"><img src="assets/sofabuffers_logo.png"'),
      reason: '§9.1 requires the centered logo',
    );
    expect(
      readme.split('\n'),
      contains('# SofaBuffers'),
      reason: "§9.1 requires the '# SofaBuffers' title",
    );
    expect(
      readme,
      contains('<b>Structured Objects For Anyone</b><br>'),
      reason: '§9.1 requires the tagline',
    );
    expect(
      readme,
      contains('https://github.com/sofa-buffers'),
      reason: '§9.1 requires a link back to the organization',
    );
  });

  test('§9.2 the library section opens with CI, coverage and Docs badges', () {
    // Everything between the library heading and the first blank line after
    // it: §9.2 puts the badges first, ahead of the GitHub link and summary.
    final block = <String>[];
    var inside = false;
    for (final line in _prose(readme)) {
      if (RegExp(r'^## SofaBuffers .* library$').hasMatch(line.trimRight())) {
        inside = true;
        continue;
      }
      if (!inside) continue;
      if (line.trim().isEmpty) {
        if (block.isNotEmpty) break;
        continue;
      }
      block.add(line);
    }
    expect(
      block,
      isNotEmpty,
      reason: '§9.2 the library section opens with no badge block',
    );

    // Badge alt texts in document order: "[![CI](…)](…)" -> "CI".
    final order = <String>[
      for (final line in block)
        if (RegExp(r'^\[!\[([^\]]*)\]').firstMatch(line) case final m?)
          m.group(1)!.toLowerCase(),
    ];
    for (final want in ['ci', 'coverage', 'docs']) {
      expect(
        order,
        contains(want),
        reason: '§9.2 the badge block carries no $want badge (it has: $order)',
      );
    }
    expect(
      [
        for (final badge in order)
          if (const ['ci', 'coverage', 'docs'].contains(badge)) badge,
      ],
      ['ci', 'coverage', 'docs'],
      reason: '§9.2 lists the badges in the CI / coverage / Docs order',
    );
  });

  test('§9 the top-level sections are the prescribed list, in order', () {
    final got = [
      for (final heading in _headings(readme))
        if (heading.level == 2) heading.text,
    ];
    for (final name in got) {
      expect(
        _topLevelSections,
        contains(name),
        reason:
            '§9 invented top-level section "$name" — "do not invent new '
            'top-level sections"; demote it to a `###` subsection of the '
            'chapter it belongs to',
      );
    }
    expect(
      got,
      _topLevelSections,
      reason: '§9 fixes both the membership and the order of the chapters',
    );
  });

  test('§9.4 there is no API-documentation section at any level', () {
    const forbidden = [
      'api reference',
      'api documentation',
      'api docs',
      'source documentation',
    ];
    for (final heading in _headings(readme)) {
      expect(
        forbidden,
        isNot(contains(heading.text.toLowerCase())),
        reason:
            '§9.4 forbids an API-documentation chapter ("${heading.text}"); '
            'the Docs badge is the only pointer',
      );
    }
  });

  test('§9.5 the Usage chapter shows every example the plan lists', () {
    final subsections = [
      for (final line in _prose(readme))
        if (line.startsWith('### ')) line.substring(4).trim(),
    ];
    final usage = _chapter(readme, 'Usage');
    for (final example in _usageExamples) {
      final heading = subsections.firstWhere(
        (s) => s.startsWith(example),
        orElse: () => '',
      );
      expect(
        heading,
        isNotEmpty,
        reason: '§9.5 Usage has no "### $example…" example',
      );
      expect(
        usage,
        contains('### $heading'),
        reason: '§9.5 the "$heading" example left the Usage chapter',
      );
    }
  });

  test('§9.6 MIN_OUTPUT_BUFFER is stated in the memory chapter', () {
    expect(
      _chapter(readme, 'Memory handling'),
      contains('MIN_OUTPUT_BUFFER'),
      reason:
          '§9.6 puts MIN_OUTPUT_BUFFER in "## Memory handling" — the number a '
          'caller needs before it can size a streaming buffer, in the section '
          'they read to find out who allocates what',
    );
  });

  test('§6.5 the raw fp32-bytes path is documented', () {
    // Dart's only floating type is `double`, which quiets a signaling NaN on
    // the way in, so §6.5 makes a raw-wire-bytes channel mandatory for this
    // port — and a channel nobody is told about is one nobody uses.
    for (final symbol in ['onFp32Bits', 'writeFp32Bits']) {
      expect(
        readme,
        contains(symbol),
        reason:
            '§6.5 double-only target: the README never mentions $symbol, so a '
            'reader cannot round-trip an fp32 signaling NaN bit-for-bit',
      );
    }
  });

  test('§6.1.1 no name outside the closed generated-object set', () {
    final offenders = _forbiddenNames
        .allMatches(readme)
        .map((m) => m.group(0)!)
        .toSet();
    expect(
      offenders,
      isEmpty,
      reason:
          '§6.1.1 closes the generated-object names to encode / decode / '
          'try_decode / serialize / deserialize / decoder',
    );
  });

  test('every in-document link resolves to a heading', () {
    // A heading that moves takes its anchor with it — the cheapest way for a
    // restructuring to break navigation while breaking nothing a build sees.
    final anchors = {for (final h in _headings(readme)) h.anchor};
    final links = RegExp(
      r'\]\(#([^)]+)\)',
    ).allMatches(readme).map((m) => m.group(1)!).toSet();
    expect(
      links,
      isNotEmpty,
      reason: 'no in-document links found; the link scan is broken',
    );
    for (final link in links) {
      expect(
        anchors,
        contains(link),
        reason: 'the link to #$link matches no heading',
      );
    }
  });
}
