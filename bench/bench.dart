import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

import 'cpu_time.dart';
import 'workloads.dart';

// Throughput tool (BENCH_SPEC `bench`): MB/s over a ~1s CPU-time loop for encode
// and decode of the two standard workloads. Output grammar is fixed — the
// central harness parses it into the cross-language comparison tables.
//
//   dart run bench/bench.dart

const double _targetSeconds = 1.0;

double _measure(int bytesPerOp, void Function() op) {
  // Warmup.
  for (var i = 0; i < 1000; i++) {
    op();
  }
  final clock = CpuClock();
  final start = clock.seconds();
  var iters = 0;
  var elapsed = 0.0;
  const batch = 200;
  while (elapsed < _targetSeconds) {
    for (var i = 0; i < batch; i++) {
      op();
    }
    iters += batch;
    elapsed = clock.seconds() - start;
  }
  return bytesPerOp * iters / elapsed / 1e6;
}

void main() {
  final u64 = buildU64Array();

  // Reusable encoder + buffer (hot path allocates nothing).
  final scratch = Uint8List(16 * 1024);
  final enc = sofab.Encoder((_) {}, buffer: scratch);
  int encodeOnce(void Function(sofab.Encoder) build) {
    enc.reset();
    build(enc);
    return enc.pending;
  }

  final typicalBytes = sofab.Encoder.encodeToBytes(encodeTypical);
  final u64Bytes = sofab.Encoder.encodeToBytes((e) => encodeU64Array(e, u64));
  final visitor = CountingVisitor();

  final encU64 = _measure(
    u64Bytes.length,
    () => encodeOnce((e) => encodeU64Array(e, u64)),
  );
  final encTypical = _measure(
    typicalBytes.length,
    () => encodeOnce(encodeTypical),
  );
  final decU64 = _measure(
    u64Bytes.length,
    () => sofab.Decoder.decode(u64Bytes, visitor),
  );
  final decTypical = _measure(
    typicalBytes.length,
    () => sofab.Decoder.decode(typicalBytes, visitor),
  );

  final b = StringBuffer();
  b.writeln('=== SofaBuffers Dart throughput (CPU time, MB/s) ===');
  // Header/dashes share the row column widths (26 + 12) so the value column
  // lines up exactly with the data rows (BENCH_SPEC).
  b.writeln('Workload'.padRight(26) + 'MB/s'.padLeft(12));
  b.writeln('--------'.padRight(26) + '----'.padLeft(12));
  b.writeln(_row('encode: u64 array (1000)', encU64));
  b.writeln(_row('encode: typical message', encTypical));
  b.writeln(_row('decode: u64 array (1000)', decU64));
  b.writeln(_row('decode: typical message', decTypical));
  b.writeln();
  b.write('MB = 1e6 bytes. ~1s CPU-time loop per workload.');
  // ignore: avoid_print
  print(b.toString());
}

String _row(String label, double mbps) =>
    label.padRight(26) + mbps.toStringAsFixed(2).padLeft(12);
