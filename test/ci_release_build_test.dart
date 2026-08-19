// CORELIB_PLAN §12.1 — *Required steps*, step 4: "Build in both debug and
// release configurations."
//
// For Dart, `dart run` / `dart test` **is** the debug (JIT) configuration; the
// release configuration is AOT (`dart compile exe`). A workflow that only ever
// runs the JIT VM proves nothing about the AOT toolchain, so an AOT-only break
// ships unnoticed. This test insists CI reaches `dart compile exe` at all.
//
// It deliberately does not say *which* entrypoint is compiled. It used to
// require every entrypoint the `bench/*.sh` scripts compile, which only held
// while CI ran those scripts; CI no longer runs benchmarks at all, because
// CORELIB_PLAN asks for none (§12.1's required steps carry no benchmark step,
// and §13 asks only that the tools be present and runnable). The benchmark
// tools stay covered by `bench_grammar_test.dart`, which runs them from the
// suite.

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

void main() {
  late String ci;

  setUpAll(() => ci = _repoFile('.github/workflows/ci.yml'));

  test('CI builds the release (AOT) configuration (§12.1 step 4)', () {
    final built = _compileExe.allMatches(ci).map((m) => m.group(1)!).toSet();
    expect(
      built,
      isNotEmpty,
      reason:
          'ci.yml never reaches `dart compile exe`, so only the debug (JIT) '
          'configuration is ever built — CORELIB_PLAN §12.1 requires both',
    );
    for (final entrypoint in built) {
      expect(
        File(entrypoint).existsSync(),
        isTrue,
        reason: 'ci.yml AOT-compiles $entrypoint, which does not exist',
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
          'CI and the bench scripts compile into build/; it must never be '
          'committed',
    );
  });
}
