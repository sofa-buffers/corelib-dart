import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The measured half of CORELIB_PLAN §6.6.4.
///
/// §6.6 forbids the codec payload storage, and §6.6.4 says reading the source
/// is not enough to show it — "an indirect allocation through a
/// caller-supplied container leaves no `malloc` in the source to find".
/// Conformance requires the number as well, and for a runtime that boxes the
/// codec's values — Dart boxes an integer above 2^62, and a `double` the
/// compiler cannot unbox — the number to show is that it
///
///   "does not grow with the message: the same for a ten-byte and a
///    ten-kilobyte payload of the same field shape, and unchanged by a hostile
///    count or length".
///
/// `bench/alloc_profile.dart` produces it from the VM service's per-class
/// allocation accumulators, in a spawned isolate so the service's own RPC does
/// not land in the measurement. This runs it and asserts the claim, pairwise:
/// what a row costs must not depend on how large the payload in it is.
///
/// It needs the JIT VM's service isolate; where that cannot be started the tool
/// exits 2 and this test skips rather than reporting a pass it did not measure.
void main() {
  /// Per-op allocation of container objects a payload could land in. A row of
  /// zero reads as a few tenths either way — the floor is the service RPC's own
  /// drift — so these are the bands around it, not exact zeroes.
  const maxAllocsPerOp = 4.0;
  const maxBytesPerOp = 512.0;

  /// The same, for the difference between the 16-byte and 4096-byte rows of one
  /// field shape. A codec sizing anything from the wire moves this by the
  /// payload's own size: the same regression measured 1445 bytes/op here.
  const maxGrowthAllocs = 3.0;
  const maxGrowthBytes = 512.0;

  test('the codec does not allocate, and does not grow with the message', () {
    final r = Process.runSync(Platform.resolvedExecutable, [
      'run',
      'bench/alloc_profile.dart',
      '--json',
      '--quick',
    ], workingDirectory: Directory.current.path);

    if (r.exitCode == 2) {
      markTestSkipped('no VM service available: ${r.stderr}');
      return;
    }
    expect(
      r.exitCode,
      0,
      reason: 'alloc_profile failed\n${r.stdout}\n${r.stderr}',
    );

    final rows = (jsonDecode((r.stdout as String).trim()) as Map)
        .cast<String, Object?>();
    expect(rows.length, greaterThan(20));

    double allocs(String name) =>
        ((rows[name]! as Map)['allocs']! as num).toDouble();
    double bytes(String name) =>
        ((rows[name]! as Map)['bytes']! as num).toDouble();

    for (final name in rows.keys) {
      expect(
        allocs(name).abs(),
        lessThan(maxAllocsPerOp),
        reason: '$name: ${allocs(name).toStringAsFixed(2)} containers per op',
      );
      expect(
        bytes(name).abs(),
        lessThan(maxBytesPerOp),
        reason: '$name: ${bytes(name).toStringAsFixed(1)} bytes per op',
      );
    }

    // The pairs: one field shape at 16 bytes of payload and at 4096.
    for (final shape in const [
      ['encode: blob ', ' B'],
      ['encode: utf8 string ', ' B'],
      ['decode: blob ', ' B, one-shot'],
      ['decode: blob ', ' B, streaming'],
      ['decode: fp64 array ', ' B, one-shot'],
      ['decode: fp64 array ', ' B, streaming'],
      ['decode: u64 array ', ' B, one-shot'],
      ['decode: u64 array ', ' B, streaming'],
    ]) {
      final small = '${shape[0]}16${shape[1]}';
      final large = '${shape[0]}4096${shape[1]}';
      expect(rows.keys, containsAll([small, large]));
      expect(
        (allocs(large) - allocs(small)).abs(),
        lessThan(maxGrowthAllocs),
        reason: '${shape[0]}: allocations grew with the payload',
      );
      expect(
        (bytes(large) - bytes(small)).abs(),
        lessThan(maxGrowthBytes),
        reason:
            '${shape[0]}: allocated bytes grew with the payload — '
            '${bytes(small).toStringAsFixed(1)} at 16 B, '
            '${bytes(large).toStringAsFixed(1)} at 4096 B',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
