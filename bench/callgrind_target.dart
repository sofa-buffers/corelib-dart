// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;

import 'workloads.dart';

// Callgrind two-rep-subtraction target (BENCH_SPEC instruction-cost tool). Runs
// exactly `reps` ops of one workload, then exits. run_callgrind.sh runs this at
// two rep counts under Callgrind and subtracts, cancelling startup/setup cost.
//
//   callgrind_target <workload> <reps>
//   workload ∈ { enc_u64, enc_typical, enc_blob_oneshot, enc_blob_streaming,
//                enc_composite, dec_u64, dec_typical, dec_blob, dec_composite,
//                dec_composite_skip, dec_u64_stream, dec_typical_stream }
//
// The first ten are the BENCH_SPEC workloads run_callgrind.sh reports. The two
// `_stream` ones are the small decodes driven through `Decoder.feed` instead of
// the one-shot surface, so the streaming path's per-op cost can be measured the
// same deterministic way; they are off the reported table because BENCH_SPEC
// does not define them, and the cross-language tables must stay comparable.
//
// Everything a workload needs is built **before** the loop, so allocation and
// pre-encoding sit in the fixed cost the subtraction cancels rather than in the
// per-op figure. The `blob 1MB` rows are the exception worth naming: their
// setup is a megabyte, which is precisely why BENCH_SPEC lets those rows run at
// R1 = 1 / R2 = 3 — the subtraction cancels fixed cost just as well at three
// reps as at three hundred.
//
// **An Ir/op figure belongs to the binary it was measured in.** Growing this
// file from four workloads to ten moved the four pre-existing rows by 1.5–6 %
// (`encode: typical message` 1011 → 1071, `decode: typical message` 2127 →
// 2251, `decode: u64 array (1000)` 102 076 → 103 604) without a line of `lib/`
// changing: a second `MessageVisitor` subclass and a second flavour of `String`
// now reach call sites that used to see exactly one class, and Dart AOT's
// monomorphic dispatch degrades accordingly. The C++ port hit the same effect
// far harder (up to 47 %, from GCC's translation-unit-wide inlining budget) and
// pinned it with `flatten`; there is no equivalent knob here, so the rule is
// simply that rows are compared **within one run of this tool**, and a
// regression gate re-measures the whole table rather than one row.

void main(List<String> args) {
  final workload = args[0];
  final reps = int.parse(args[1]);

  final u64 = buildU64Array();
  final scratch = Uint8List(16 * 1024);
  final enc = sofab.Encoder((_) {}, buffer: scratch);
  final visitor = CountingVisitor();
  final skipper = SkipAllVisitor();

  final u64Bytes = sofab.Encoder.encodeToBytes((e) => encodeU64Array(e, u64));
  final typicalBytes = sofab.Encoder.encodeToBytes(encodeTypical);
  final compBytes = sofab.Encoder.encodeToBytes(encodeComposite);

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
    case 'enc_composite':
      for (var i = 0; i < reps; i++) {
        enc.reset();
        encodeComposite(enc);
        sink += enc.pending;
      }
      break;
    case 'enc_blob_oneshot':
      // The floor: one contiguous write into a caller buffer sized by hand to
      // the encoded size, with no sink at all (BENCH_SPEC).
      final blob = buildBlob();
      final out = Uint8List(blobEncodedSize);
      for (var i = 0; i < reps; i++) {
        final e = sofab.Encoder.overBuffer(out);
        encodeBlob(e, blob);
        e.flush();
        sink += e.written.length;
      }
      break;
    case 'enc_blob_streaming':
      // The same bytes through ~245 flushes of a 4096-byte buffer, pass-through
      // not granted — the divisible-run path of CORELIB_PLAN §5.1. Its gap to
      // the one-shot row is what the flush machinery costs, and this is the one
      // place in the suite that path is exercised at all.
      final blob = buildBlob();
      final buf = Uint8List(blobChunk);
      final discard = DiscardSink();
      for (var i = 0; i < reps; i++) {
        final e = sofab.Encoder(discard.add, buffer: buf);
        encodeBlob(e, blob);
        e.flush();
      }
      sink += discard.acc;
      break;
    case 'dec_blob':
      final blob = buildBlob();
      final wire = sofab.Encoder.encodeToBytes(
        (e) => encodeBlob(e, blob),
        bufferSize: 64 * 1024,
      );
      for (var i = 0; i < reps; i++) {
        final dec = sofab.Decoder(visitor);
        for (var off = 0; off < wire.length; off += blobChunk) {
          final end = off + blobChunk;
          dec.feed(
            Uint8List.sublistView(
              wire,
              off,
              end < wire.length ? end : wire.length,
            ),
          );
        }
        sink += visitor.fields;
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
    case 'dec_composite':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder.decode(compBytes, visitor);
        sink += visitor.fields;
      }
      break;
    case 'dec_composite_skip':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder.decode(compBytes, skipper);
        sink += skipper.skipped;
      }
      break;
    case 'dec_u64_stream':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder(visitor).feed(u64Bytes);
        sink += visitor.fields;
      }
      break;
    case 'dec_typical_stream':
      for (var i = 0; i < reps; i++) {
        sofab.Decoder(visitor).feed(typicalBytes);
        sink += visitor.fields;
      }
      break;
    default:
      throw ArgumentError('unknown workload $workload');
  }
  // Prevent the loop from being optimized away.
  if (sink == -1) print(sink);
}
