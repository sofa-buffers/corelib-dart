import 'package:sofabuffers/sofabuffers.dart' as sofab;

import 'workloads.dart';

// Prints "<u64_array_size> <typical_size>" — the encoded message sizes used as
// the `bytes` column of run_callgrind.sh (must match perf's `message size`).
void main() {
  final u64 = buildU64Array();
  final u64Size =
      sofab.Encoder.encodeToBytes((e) => encodeU64Array(e, u64)).length;
  final typicalSize = encodedSize(encodeTypical);
  // ignore: avoid_print
  print('$u64Size $typicalSize');
}
