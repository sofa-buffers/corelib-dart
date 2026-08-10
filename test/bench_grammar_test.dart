// BENCH_SPEC's output grammar, enforced.
//
// The central harness parses each port's `bench` and `perf` output with fixed
// regexes and drops anything that does not match — "Output that doesn't match
// this grammar will not be parsed into the comparison tables". A port whose
// table has drifted therefore does not fail loudly; it silently disappears from
// the comparison. These tests are the loud failure.
//
// They run `bench` in its `--smoke` mode (one op per row, ~0.5 s) rather than
// the ~12 s measuring mode: the grammar is a property of the *table*, and the
// same code prints it either way. `perf` runs for real — its two sections are
// short — and `run_callgrind.sh` is checked by reading it, since a Callgrind
// pass over a megabyte-sized workload does not belong in the unit suite.

import 'dart:io';

import 'package:test/test.dart';

/// The harness's own regexes (BENCH_SPEC "Output grammar").
final RegExp _throughputHeader = RegExp(r'=== SofaBuffers (.+?) throughput');
final RegExp _perOpHeader = RegExp(r'=== SofaBuffers (.+?) per-op');
final RegExp _row = RegExp(
  r'^(encode|decode):\s+'
  r'(u64 array \(1000\)|typical message|blob 1MB one-shot|'
  r'blob 1MB streaming|blob 1MB passthrough|blob 1MB|'
  r'composite skip-all|composite)\s+([\d.]+)$',
);

/// Every row BENCH_SPEC requires, in the order the sample table prints them.
/// `encode: blob 1MB passthrough` is absent on purpose: it is the one optional
/// row, and this port implements no pass-through, so it must print no
/// placeholder in its place.
const List<String> _requiredRows = [
  'encode: u64 array (1000)',
  'encode: typical message',
  'encode: blob 1MB one-shot',
  'encode: blob 1MB streaming',
  'encode: composite',
  'decode: u64 array (1000)',
  'decode: typical message',
  'decode: blob 1MB',
  'decode: composite',
  'decode: composite skip-all',
];

ProcessResult _run(List<String> args) {
  final r = Process.runSync('dart', ['run', ...args]);
  expect(
    r.exitCode,
    0,
    reason: 'dart run ${args.join(' ')} failed:\n${r.stdout}\n${r.stderr}',
  );
  return r;
}

void main() {
  group('bench (throughput)', () {
    late List<String> lines;

    setUpAll(() {
      lines = (_run(['bench/bench.dart', '--smoke']).stdout as String).split(
        '\n',
      );
    });

    test('the label the harness keys the display name off is "Dart"', () {
      final m = _throughputHeader.firstMatch(lines.first);
      expect(m, isNotNull, reason: 'first line: ${lines.first}');
      expect(m!.group(1), 'Dart');
      expect(
        lines.first,
        '=== SofaBuffers Dart throughput (CPU time, MB/s) ===',
      );
    });

    test('every required row is present, in order, and parses', () {
      final matched = <String>[];
      for (final line in lines) {
        final m = _row.firstMatch(line);
        if (m == null) continue;
        matched.add('${m.group(1)}: ${m.group(2)}');
        expect(double.tryParse(m.group(3)!), isNotNull);
      }
      expect(matched, _requiredRows);
    });

    test('rows are 26-wide label + 12-wide value, as BENCH_SPEC lays out', () {
      for (final line in lines.where(_row.hasMatch)) {
        expect(line.length, 39, reason: line);
        expect(line.substring(26, 27), ' ', reason: line);
        expect(line.substring(27).trimLeft(), matches(r'^\d+\.\d\d$'));
      }
      // The header and the dashes share the row layout, so the value column
      // lines up with the numbers beneath it.
      expect(lines[1], '${'Workload'.padRight(26)} ${'MB/s'.padLeft(12)}');
      expect(lines[2], '${'--------'.padRight(26)} ${'----'.padLeft(12)}');
    });

    test('the MB convention is restated where BENCH_SPEC puts it', () {
      expect(
        lines,
        contains('MB = 1e6 bytes. ~1s CPU-time loop per workload.'),
      );
    });
  });

  group('perf (per-op)', () {
    late String out;

    setUpAll(() => out = _run(['bench/perf.dart']).stdout as String);

    test('the header carries the same short, stable label', () {
      expect(_perOpHeader.firstMatch(out)?.group(1), 'Dart');
    });

    test('both markers are present', () {
      expect(out, contains('perf: serialize'));
      expect(out, contains('perf: deserialize'));
    });

    test('the five value lines appear in each section', () {
      expect(RegExp(r'  iterations    : \d+').allMatches(out).length, 2);
      expect(RegExp(r'  message size  : 170 bytes').allMatches(out).length, 2);
      // No hardware cycle counter on the Dart VM: BENCH_SPEC's parenthetical.
      expect(
        RegExp(
          r'  cycles/op     : \(cycle counter unavailable',
        ).allMatches(out).length,
        2,
      );
      expect(
        RegExp(
          r'  CPU time/op   : [\d.]+ ns  \(process CPU time',
        ).allMatches(out).length,
        2,
      );
      expect(
        RegExp(
          r'  throughput    : [\d.]+ MB/s  \(speedtest',
        ).allMatches(out).length,
        2,
      );
    });

    test('the trailing line BENCH_SPEC keeps on every implementation', () {
      expect(
        out,
        contains("cycles/op tracks code cost; MB/s is this machine's"),
      );
    });
  });

  group('run_callgrind.sh (instruction cost)', () {
    late String script;

    setUpAll(() => script = File('bench/run_callgrind.sh').readAsStringSync());

    test('reports every required workload', () {
      for (final row in _requiredRows) {
        expect(script, contains("'$row'"), reason: row);
      }
    });

    test('omits the optional passthrough row rather than stubbing it', () {
      expect(script, isNot(contains("'encode: blob 1MB passthrough'")));
    });

    test('drives the blob rows at the small rep pair BENCH_SPEC allows', () {
      expect(script, contains('BLOB_R1=1'));
      expect(script, contains('BLOB_R2=3'));
    });
  });
}
