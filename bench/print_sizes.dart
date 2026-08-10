import 'package:sofabuffers/sofabuffers.dart' as sofab;

import 'workloads.dart';

// Prints the encoded size of each BENCH_SPEC dataset, one per line, as
// `<workload> <bytes>` — the `bytes` column of run_callgrind.sh, which must
// match `perf`'s `message size`. The `blob 1MB` (1,000,005) and `composite`
// (956) figures are cross-port parity checks in their own right, so they are
// computed here rather than hard-coded into the shell script.
void main() {
  final u64 = buildU64Array();
  final blob = buildBlob();
  final sizes = <String, int>{
    'u64': sofab.Encoder.encodeToBytes((e) => encodeU64Array(e, u64)).length,
    'typical': encodedSize(encodeTypical),
    'blob': sofab.Encoder.encodeToBytes(
      (e) => encodeBlob(e, blob),
      bufferSize: 64 * 1024,
    ).length,
    'composite': encodedSize(encodeComposite),
  };
  if (sizes['blob'] != blobEncodedSize ||
      sizes['composite'] != compositeEncodedSize) {
    throw StateError('dataset parity check failed: $sizes');
  }
  final out = StringBuffer();
  sizes.forEach((name, bytes) => out.writeln('$name $bytes'));
  // ignore: avoid_print
  print(out.toString().trimRight());
}
