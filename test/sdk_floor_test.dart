// CORELIB_PLAN §9.2 — the README's opening section must carry **Requirements**:
// "the minimum required version of the runtime / language toolchain, plus the
// install command". A minimum that is *lower* than the one the package really
// resolves against is worse than no minimum at all: a reader on that version
// follows the install command and gets a resolution failure instead of a
// library.
//
// The floor lives in three places that must agree, and only `pubspec.yaml` is
// enforced by the toolchain:
//
// * `pubspec.yaml` `environment.sdk` — what `dart pub get` actually rejects;
// * `README.md` `### Requirements` — what a reader is told before installing;
// * `.github/workflows/ci.yml` — the lowest SDK in the test matrix, i.e. the
//   oldest version this port is ever proven to work on.
//
// So this test reads all three and fails the moment they drift apart.

import 'dart:io';

import 'package:test/test.dart';

/// A dotted version, compared and printed by its parts.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Parses `3`, `3.8` or `3.8.0` (missing parts are 0).
  static Version parse(String text) {
    final parts = text.trim().split('.');
    int at(int i) => i < parts.length ? int.parse(parts[i]) : 0;
    return Version(at(0), at(1), at(2));
  }

  /// The `major.minor` prefix, which is how the CI matrix names an SDK.
  Version get majorMinor => Version(major, minor, 0);

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// Reads a repository file, insisting the suite runs from the package root.
String repoFile(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'run `dart test` from the package root ($path not found)',
  );
  return file.readAsStringSync();
}

void main() {
  late Version pubspecFloor;

  setUpAll(() {
    final pubspec = repoFile('pubspec.yaml');
    // `environment:` / `  sdk: ^3.8.0` — a caret or `>=` bound both state the
    // same floor.
    final match = RegExp(
      r'^\s*sdk:\s*[\x27"]?\s*(?:\^|>=)?\s*(\d+(?:\.\d+){0,2})',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      match,
      isNotNull,
      reason: 'pubspec.yaml declares no environment.sdk bound',
    );
    pubspecFloor = Version.parse(match!.group(1)!);
  });

  test(
    'README `### Requirements` states the SDK floor pubspec.yaml enforces',
    () {
      final readme = repoFile('README.md');
      final start = readme.indexOf('\n### Requirements');
      expect(
        start,
        greaterThan(-1),
        reason: '§9.2 Requirements section is missing',
      );
      final rest = readme.substring(start + 1);
      final end = rest.indexOf('\n#', 1);
      final section = end < 0 ? rest : rest.substring(0, end);

      final match = RegExp(
        r'Dart SDK\s*(?:>=|≥|&ge;)\s*(\d+(?:\.\d+){0,2})',
      ).firstMatch(section);
      expect(
        match,
        isNotNull,
        reason:
            'the Requirements section must name a minimum Dart SDK version '
            '(CORELIB_PLAN §9.2); section was:\n$section',
      );
      final documented = Version.parse(match!.group(1)!);

      expect(
        documented,
        pubspecFloor,
        reason:
            'README promises Dart SDK >= $documented but `dart pub get` rejects '
            'anything below $pubspecFloor (pubspec.yaml environment.sdk) — a '
            'reader between the two follows the install command and gets a '
            'resolution failure',
      );
    },
  );

  test('README `### Requirements` carries the install command (§9.2)', () {
    final readme = repoFile('README.md');
    final start = readme.indexOf('\n### Requirements');
    final rest = readme.substring(start + 1);
    final end = rest.indexOf('\n#', 1);
    final section = end < 0 ? rest : rest.substring(0, end);
    expect(
      section.contains('dart pub add sofabuffers'),
      isTrue,
      reason: '§9.2 requires the install command next to the minimum version',
    );
  });

  test('the CI matrix floor is the SDK floor pubspec.yaml enforces', () {
    final ci = repoFile('.github/workflows/ci.yml');
    final line = RegExp(
      r'^\s*sdk:\s*\[(.+)\]\s*$',
      multiLine: true,
    ).firstMatch(ci);
    expect(line, isNotNull, reason: 'ci.yml declares no `sdk:` matrix');

    final numbered =
        line!
            .group(1)!
            .split(',')
            .map((leg) => leg.trim().replaceAll(RegExp('[\'"]'), ''))
            .where((leg) => RegExp(r'^\d').hasMatch(leg))
            .map(Version.parse)
            .toList()
          ..sort();
    expect(
      numbered,
      isNotEmpty,
      reason: 'the matrix pins no numbered SDK, so no floor is ever proven',
    );

    expect(
      numbered.first,
      pubspecFloor.majorMinor,
      reason:
          'CI proves the port on ${numbered.first} upwards but pubspec.yaml '
          'admits $pubspecFloor — the lowest supported SDK must be the one '
          'that is tested',
    );
  });
}
