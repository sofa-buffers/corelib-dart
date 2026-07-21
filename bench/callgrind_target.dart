// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

import 'workloads.dart';

// Callgrind two-rep-subtraction target (BENCH_SPEC instruction-cost tool). Runs
// exactly `reps` ops of one workload, then exits. run_callgrind.sh runs this at
// two rep counts under Callgrind and subtracts, cancelling startup/setup cost.
//
//   callgrind_target <workload> <reps>
//   workload ∈ { enc_u64, enc_typical, dec_u64, dec_typical }

void main(List<String> args) {
  final workload = args[0];
  final reps = int.parse(args[1]);

  final u64 = buildU64Array();
  final scratch = Uint8List(16 * 1024);
  final enc = sofab.Encoder((_) {}, buffer: scratch);
  final visitor = CountingVisitor();

  final u64Bytes = sofab.Encoder.encodeToBytes((e) => encodeU64Array(e, u64));
  final typicalBytes = sofab.Encoder.encodeToBytes(encodeTypical);

  var sink = 0;
  switch (workload) {
    case 'enc_u64':
      for (var i = 0; i < reps; i++) {
        enc.reset();
        encodeU64Array(enc, u64);
        sink += enc.pending;
      }
      break;
    case 'enc_typical':
      for (var i = 0; i < reps; i++) {
        enc.reset();
        encodeTypical(enc);
        sink += enc.pending;
      }
      break;
    case 'dec_u64':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder.decode(u64Bytes, visitor);
        sink += visitor.fields;
      }
      break;
    case 'dec_typical':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder.decode(typicalBytes, visitor);
        sink += visitor.fields;
      }
      break;
    default:
      throw ArgumentError('unknown workload $workload');
  }
  // Prevent the loop from being optimized away.
  if (sink == -1) print(sink);
}
