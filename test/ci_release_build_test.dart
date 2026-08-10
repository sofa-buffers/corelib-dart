// CORELIB_PLAN §12.1 — *Required steps*, step 4: "Build in both debug and
// release configurations."
//
// For Dart, `dart run` / `dart test` **is** the debug (JIT) configuration; the
// release configuration is AOT (`dart compile exe`). A workflow that only ever
// runs the JIT VM proves nothing about the AOT toolchain, so an AOT-only break
// — in the library, in an entrypoint, or in the two benchmark scripts the
// README calls the recommended way to measure — ships unnoticed.
//
// The AOT entrypoints are not a list this test invents: they are exactly the
// files `bench/*.sh` feeds to `dart compile exe`. This test reads them out of
// the scripts and insists CI builds every one of them, so adding an AOT
// entrypoint to a script without teaching CI about it fails here rather than
// months later on someone's laptop.

import 'dart:io';

import 'package:test/test.dart';

/// Reads a repository file, insisting the suite runs from the package root.
String _repoFile(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'run `dart test` from the package root ($path not found)',
  );
  return file.readAsStringSync();
}

/// `dart compile exe <entrypoint>` — the release build of one entrypoint.
final RegExp _compileExe = RegExp(
  r'dart\s+compile\s+exe\s+([^\s\\]+)',
  multiLine: true,
);

/// Every shell script under `bench/`, by repository-relative path.
List<String> _benchScripts() =>
    Directory('bench')
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll(r'\', '/'))
        .where((p) => p.endsWith('.sh'))
        .toList()
      ..sort();

void main() {
  late String ci;

  setUpAll(() => ci = _repoFile('.github/workflows/ci.yml'));

  /// The entrypoints CI compiles ahead-of-time: those it names itself, plus
  /// those compiled by any `bench/*.sh` script CI invokes.
  Set<String> builtInCi() {
    final built = _compileExe.allMatches(ci).map((m) => m.group(1)!).toSet();
    for (final script in _benchScripts()) {
      if (!ci.contains(script)) continue;
      built.addAll(
        _compileExe.allMatches(_repoFile(script)).map((m) => m.group(1)!),
      );
    }
    return built;
  }

  test('CI builds the release (AOT) configuration (§12.1 step 4)', () {
    expect(
      builtInCi(),
      isNotEmpty,
      reason:
          'ci.yml never reaches `dart compile exe`, directly or through a '
          'bench script, so only the debug (JIT) configuration is ever '
          'built — CORELIB_PLAN §12.1 requires both',
    );
  });

  test('every AOT entrypoint the bench scripts compile is built in CI', () {
    final built = builtInCi();
    for (final script in _benchScripts()) {
      for (final match in _compileExe.allMatches(_repoFile(script))) {
        final entrypoint = match.group(1)!;
        expect(
          built,
          contains(entrypoint),
          reason:
              '$script builds $entrypoint ahead-of-time but CI never does, so '
              'a break in that entrypoint is invisible until someone runs the '
              'script by hand',
        );
      }
    }
  });

  test('the benchmark scripts the README recommends are run by CI', () {
    final readme = _repoFile('README.md');
    final recommended = _benchScripts().where(readme.contains).toList();
    expect(
      recommended,
      isNotEmpty,
      reason: 'the README documents no benchmark script — test is stale',
    );
    for (final script in recommended) {
      expect(
        ci.contains(script),
        isTrue,
        reason:
            'the README tells readers to run $script, but CI never does, so '
            'the script itself is unbuilt and untested',
      );
    }
  });

  test('the AOT build output directory stays out of the repository', () {
    final ignored = _repoFile(
      '.gitignore',
    ).split('\n').map((line) => line.trim()).toSet();
    expect(
      ignored.contains('build/') || ignored.contains('/build/'),
      isTrue,
      reason:
          'the bench scripts compile into build/; it must never be committed',
    );
  });
}
