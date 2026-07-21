import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

import 'cpu_time.dart';
import 'workloads.dart';

// Per-op tool (BENCH_SPEC `perf`): CPU time/op + throughput for the 170-byte
// `perf` message. The Dart VM exposes no hardware cycle counter, so the
// `cycles/op` line reports it as unavailable (BENCH_SPEC). Output grammar fixed.
//
//   dart run bench/perf.dart

const double _targetSeconds = 1.0;

class _Result {
  _Result(this.iterations, this.nsPerOp, this.mbps);
  final int iterations;
  final double nsPerOp;
  final double mbps;
}

_Result _measure(int bytesPerOp, void Function() op) {
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
  final nsPerOp = elapsed / iters * 1e9;
  final mbps = bytesPerOp * iters / elapsed / 1e6;
  return _Result(iters, nsPerOp, mbps);
}

void main() {
  final size = encodedSize(encodePerf);
  final bytes = sofab.Encoder.encodeToBytes(encodePerf);

  final scratch = Uint8List(16 * 1024);
  final enc = sofab.Encoder((_) {}, buffer: scratch);
  final visitor = CountingVisitor();

  final ser = _measure(size, () {
    enc.reset();
    encodePerf(enc);
  });
  final deser = _measure(size, () => sofab.Decoder.decode(bytes, visitor));

  final b = StringBuffer();
  b.writeln(
      '=== SofaBuffers Dart per-op cost (cycles/op + throughput MB/s) ===');
  b.writeln();
  _section(b, 'serialize', size, ser);
  b.writeln();
  _section(b, 'deserialize', size, deser);
  b.writeln();
  b.write('cycles/op tracks code cost; MB/s is this machine\'s throughput.');
  // ignore: avoid_print
  print(b.toString());
}

void _section(StringBuffer b, String phase, int size, _Result r) {
  b.writeln('--- perf: $phase (stream API) ---');
  b.writeln('  iterations    : ${r.iterations}');
  b.writeln('  message size  : $size bytes');
  b.writeln('  cycles/op     : (cycle counter unavailable on Dart VM)');
  b.writeln('  CPU time/op   : ${r.nsPerOp.toStringAsFixed(1)} ns  '
      '(process CPU time, not wall-clock)');
  b.write('  throughput    : ${r.mbps.toStringAsFixed(1)} MB/s  '
      '(speedtest, MB = 1e6 bytes)');
  b.writeln();
}
