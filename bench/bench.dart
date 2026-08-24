import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;

import 'cpu_time.dart';
import 'workloads.dart';

// Throughput tool (BENCH_SPEC `bench`): MB/s over a ~1s CPU-time loop for encode
// and decode of the four standard datasets — the 1000-element `u64 array`, the
// small `typical` message, the unbounded 1 MB `blob`, and the `composite`
// message that reaches the paths the flat three never touch (wrapper array,
// multi-byte UTF-8, depth-3 nesting, an omitted default, a two-byte header).
// Output grammar is fixed — the central harness parses it into the
// cross-language comparison tables.
//
// **Read the `blob 1MB` rows against each other, not against the others.** Five
// bytes of that message are metadata and a million are payload, so its MB/s is
// this machine's memory bandwidth rather than a statement about the corelib. The
// signal is the *difference* between the one-shot and streaming rows — the cost
// of the divisible-run path (CORELIB_PLAN §5.1) — and under MB/s that difference
// is a low-single-digit fraction of a bandwidth-bound row. Read it as Callgrind
// `Ir/op` (`bench/run_callgrind.sh`), where instruction counts do not care about
// bandwidth.
//
//   dart run bench/bench.dart          (JIT)
//   bench/run_bench.sh                 (AOT — the representative figures)
//   dart run bench/bench.dart --smoke  (one op per row; see below)
//
// `--smoke` runs every workload exactly **once** and prints the same table from
// that single op. The numbers are then real but meaningless — one un-warmed op
// timed against a clock of comparable cost — so it is not a measurement and
// must not be pasted anywhere. It exists so the suite can drive every row end
// to end, and check the output against BENCH_SPEC's grammar, in a second rather
// than in the ~12 s the real loops take.

const double _targetSeconds = 1.0;
const double _batchSeconds = 0.01; // clock cost lands under ~0.01% of a batch
const double _warmupSeconds = 0.05;
const int _warmupOps = 1000;

/// Warms the code up before the timer starts (BENCH_SPEC "Timing").
///
/// BENCH_SPEC asks for one warmup call; a JIT run wants rather more than one,
/// so this does up to [_warmupOps] — but stops early once [_warmupSeconds] of
/// CPU time has gone into it. Without that ceiling the `blob 1MB` rows would
/// copy a gigabyte before measuring anything, which warms nothing that the
/// first few dozen ops did not already warm.
void _warmup(void Function() op) {
  final clock = CpuClock();
  final start = clock.seconds();
  for (var i = 0; i < _warmupOps; i++) {
    op();
    if ((i & 15) == 15 && clock.seconds() - start >= _warmupSeconds) return;
  }
}

/// Grow a batch until it spans [_batchSeconds], so the single clock read that
/// ends it is a rounding error against the work it timed. A fixed batch of 200
/// was a guess that silently degrades as ops get faster; calibrating removes
/// the guess and doubles as extra warmup.
int _calibrateBatch(void Function() op) {
  final clock = CpuClock();
  var batch = 1;
  while (true) {
    final start = clock.seconds();
    for (var i = 0; i < batch; i++) {
      op();
    }
    if (clock.seconds() - start >= _batchSeconds) return batch;
    batch *= 2;
  }
}

/// One op, timed. See `--smoke` above: this is a liveness check for the row,
/// not a measurement.
double _measureOnce(int bytesPerOp, void Function() op) {
  final clock = CpuClock();
  final start = clock.seconds();
  op();
  final elapsed = clock.seconds() - start;
  return elapsed > 0 ? bytesPerOp / elapsed / 1e6 : 0.0;
}

double Function(int, void Function()) _measure = _measureFully;

double _measureFully(int bytesPerOp, void Function() op) {
  _warmup(op);
  final batch = _calibrateBatch(op);
  final clock = CpuClock();
  final start = clock.seconds();
  var iters = 0;
  var elapsed = 0.0;
  while (elapsed < _targetSeconds) {
    for (var i = 0; i < batch; i++) {
      op();
    }
    iters += batch;
    elapsed = clock.seconds() - start;
  }
  return bytesPerOp * iters / elapsed / 1e6;
}

/// Feeds [wire] to a fresh streaming decoder in [blobChunk]-byte pieces — the
/// `decode: blob 1MB` row, and the only decode row in the suite driven through
/// the chunked surface rather than the one-shot one.
int _decodeChunked(Uint8List wire, CountingVisitor visitor) {
  final dec = sofab.Decoder(visitor);
  for (var off = 0; off < wire.length; off += blobChunk) {
    final end = off + blobChunk;
    dec.feed(
      Uint8List.sublistView(wire, off, end < wire.length ? end : wire.length),
    );
  }
  return visitor.fields;
}

void main(List<String> args) {
  if (args.contains('--smoke')) _measure = _measureOnce;
  final u64 = buildU64Array();
  final blob = buildBlob();

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
  final compBytes = sofab.Encoder.encodeToBytes(encodeComposite);
  final blobBytes = sofab.Encoder.encodeToBytes(
    (e) => encodeBlob(e, blob),
    bufferSize: 64 * 1024,
  );
  if (blobBytes.length != blobEncodedSize ||
      compBytes.length != compositeEncodedSize) {
    throw StateError(
      'dataset parity check failed: blob=${blobBytes.length} '
      '(want $blobEncodedSize), composite=${compBytes.length} '
      '(want $compositeEncodedSize)',
    );
  }
  final visitor = CountingVisitor();
  final skipper = SkipAllVisitor();

  // The `blob 1MB` encode targets. The one-shot buffer is sized **by hand** to
  // exactly the encoded size (BENCH_SPEC): the schema is unbounded, so there is
  // no `MAX_SIZE` to take it from, and the row is the floor — one contiguous
  // write into a caller buffer with no sink at all. The streaming row is the
  // same bytes through ~245 flushes of a 4096-byte buffer, pass-through not
  // granted, so it measures the copy path (§5.1).
  final blobOneShotBuf = Uint8List(blobEncodedSize);
  final blobStreamBuf = Uint8List(blobChunk);
  final blobSink = DiscardSink();

  final encU64 = _measure(
    u64Bytes.length,
    () => encodeOnce((e) => encodeU64Array(e, u64)),
  );
  final encTypical = _measure(
    typicalBytes.length,
    () => encodeOnce(encodeTypical),
  );
  final encBlobOneShot = _measure(blobEncodedSize, () {
    final e = sofab.Encoder.overBuffer(blobOneShotBuf);
    encodeBlob(e, blob);
    e.flush();
  });
  final encBlobStreaming = _measure(blobEncodedSize, () {
    final e = sofab.Encoder(blobSink.add, buffer: blobStreamBuf);
    encodeBlob(e, blob);
    e.flush();
  });
  final encComposite = _measure(
    compBytes.length,
    () => encodeOnce(encodeComposite),
  );
  final decU64 = _measure(
    u64Bytes.length,
    () => sofab.Decoder.decode(u64Bytes, visitor),
  );
  final decTypical = _measure(
    typicalBytes.length,
    () => sofab.Decoder.decode(typicalBytes, visitor),
  );
  final decBlob = _measure(
    blobEncodedSize,
    () => _decodeChunked(blobBytes, visitor),
  );
  final decComposite = _measure(
    compBytes.length,
    () => sofab.Decoder.decode(compBytes, visitor),
  );
  final decCompositeSkip = _measure(
    compBytes.length,
    () => sofab.Decoder.decode(compBytes, skipper),
  );

  final b = StringBuffer();
  b.writeln('=== SofaBuffers Dart throughput (CPU time, MB/s) ===');
  // Header/dashes share the row column widths (26 + 1 + 12) so the value column
  // lines up exactly with the data rows (BENCH_SPEC).
  b.writeln('${'Workload'.padRight(26)} ${'MB/s'.padLeft(12)}');
  b.writeln('${'--------'.padRight(26)} ${'----'.padLeft(12)}');
  b.writeln(_row('encode: u64 array (1000)', encU64));
  b.writeln(_row('encode: typical message', encTypical));
  b.writeln(_row('encode: blob 1MB one-shot', encBlobOneShot));
  b.writeln(_row('encode: blob 1MB streaming', encBlobStreaming));
  // `encode: blob 1MB passthrough` is BENCH_SPEC's one optional row, and this
  // port implements no pass-through (CORELIB_PLAN §5.1 makes it a MAY): every
  // `string`/`blob` run goes through the output buffer. The row is therefore
  // omitted entirely rather than printed as a placeholder.
  b.writeln(_row('encode: composite', encComposite));
  b.writeln(_row('decode: u64 array (1000)', decU64));
  b.writeln(_row('decode: typical message', decTypical));
  b.writeln(_row('decode: blob 1MB', decBlob));
  b.writeln(_row('decode: composite', decComposite));
  b.writeln(_row('decode: composite skip-all', decCompositeSkip));
  b.writeln();
  b.writeln('MB = 1e6 bytes. ~1s CPU-time loop per workload.');
  b.write(
    'blob 1MB is bandwidth-bound: read one-shot vs streaming, not either alone.',
  );
  // ignore: avoid_print
  print(b.toString());
  // Keep the discard sink's fold (and the visitors' counters) observable so the
  // measured loops cannot be optimised away.
  if (blobSink.acc == -1 || visitor.fields == -1 || skipper.skipped == -1) {
    // ignore: avoid_print
    print(blobSink.acc + visitor.fields + skipper.skipped);
  }
}

String _row(String label, double mbps) =>
    '${label.padRight(26)} ${mbps.toStringAsFixed(2).padLeft(12)}';
