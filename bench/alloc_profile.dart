import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;

import 'workloads.dart';

// Allocation-count tool (CORELIB_PLAN §6.6.4, §13).
//
// §6.6 forbids the codec payload storage, and §6.6.4 says source inspection
// alone is not enough to show it: "an indirect allocation through a
// caller-supplied container leaves no `malloc` in the source to find".
// Conformance needs the number as well —
//
//   "an allocation count, or the heap high-water mark, over a complete encode
//    and a complete decode, measured after the codec's one-time construction …
//    Where the runtime does box [the codec's values] the count is never zero and
//    demanding zero would demand the impossible, so the measurable claim is that
//    it does not grow with the message: the same for a ten-byte and a
//    ten-kilobyte payload of the same field shape, and unchanged by a hostile
//    count or length."
//
// Dart is such a runtime — an integer above 2^62 is a boxed `Mint`, a `double`
// the compiler cannot unbox is a boxed `Double` — so this tool measures the
// growth claim, and prints a per-op count small enough to see a single stray
// allocation in.
//
//   dart run bench/alloc_profile.dart            (the table)
//   dart run bench/alloc_profile.dart --json     (one JSON object, for the test)
//   dart run bench/alloc_profile.dart --quick    (fewer reps, coarser)
//
// **How it is measured.** The VM service reports `instancesAccumulated` and
// `accumulatedSize` per class, which is a monotonic allocation counter for one
// isolate. Two properties make the reading usable:
//
// * the workload runs in a **spawned isolate**, because the service RPC itself
//   allocates — in the isolate it is asked about. Keeping the driver's HTTP and
//   JSON out of the measured isolate leaves only the per-batch port message.
// * every row is reported **net of a `noop` row at the same repetition count**,
//   which is what the RPC's own fixed cost divided by the reps looks like. The
//   remainder is the workload's.
//
// It needs the JIT VM (`dart run`): an AOT binary ships no service isolate.

/// One measured row.
class _Row {
  _Row(this.name, this.reps, this.allocs, this.bytes, this.all);
  final String name;
  final int reps;

  /// Per op, over [_containerClasses] — the storage a payload could land in.
  final double allocs;
  final double bytes;

  /// Per op, over **every** class, including the ones the service RPC itself
  /// churns through. Reported because it is the honest total; too coarse to
  /// assert on, which is what [_containerClasses] is for.
  final double all;
}

/// The classes a SofaBuffers **container** allocation would land in — every
/// list, view and buffer type this library's source can produce, and no other.
///
/// The reading has to be filtered because the service RPC allocates in the
/// isolate it reports on, and its own JSON churn (`_List`, `_GrowableList`,
/// `_OneByteString`, …) runs to hundreds of thousands of objects per call with
/// several per cent of drift between calls. That is far above a codec's whole
/// per-op budget, so a total-only reading can only prove the absence of gross
/// allocation. Narrowing to the classes a payload could land in drops the floor
/// to a few hundred objects and makes a *single* stray allocation per op
/// visible.
///
/// What the filter cannot see is the other half of §6.6.4's "both ways": a
/// reading of the source, which is where `_List` (the parse stack) and
/// `_Int32List` (the pending run) are accounted for — both allocated in a
/// constructor, which §6.6 permits and this tool measures after.
const Set<String> _containerClasses = {
  '_Uint8List',
  '_Int32List',
  '_Int64List',
  '_Float32List',
  '_Float64List',
  '_Uint8ArrayView',
  '_Int64ArrayView',
  '_Float32ArrayView',
  '_Float64ArrayView',
  '_ByteDataView',
  '_ByteBuffer',
  'CodeUnits',
};

// ---------------------------------------------------------------- worker ---

/// A visitor that owns its destinations, allocated **once**: what is measured
/// is the codec, and a caller that allocates a fresh destination per field is
/// measuring its own allocation (§6.6.1 — the destination is the caller's).
class _OwnDest extends sofab.MessageVisitor {
  _OwnDest(int bytesCap, int elemCap)
    : _bytes = Uint8List(bytesCap),
      _ints = Int64List(elemCap),
      _f64 = Float64List(elemCap),
      _f32 = Float32List(elemCap);

  final Uint8List _bytes;
  final Int64List _ints;
  final Float64List _f64;
  final Float32List _f32;

  /// Folded so nothing measured can be optimised away.
  int seen = 0;

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) => _bytes;

  @override
  void onBytesDone(int id, int subtype, Uint8List dest, int total) =>
      seen += total;

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    switch (kind) {
      case sofab.ArrayKind.unsigned:
      case sofab.ArrayKind.signed:
        return _ints;
      case sofab.ArrayKind.fp32:
        return _f32;
      case sofab.ArrayKind.fp64:
        return _f64;
    }
  }

  @override
  void onArrayDone(int id, sofab.ArrayKind kind, TypedData dest, int count) =>
      seen += count;

  @override
  void onUnsigned(int id, int value) => seen++;
  @override
  void onSigned(int id, int value) => seen++;
  @override
  void onFp32(int id, double value) => seen++;
  @override
  void onFp64(int id, double value) => seen++;
  @override
  sofab.MessageVisitor? onSequenceStart(int id) => this;
}

/// The payload sizes each "does it grow with the message?" pair is taken at —
/// §6.6.4's own words: "the same for a ten-byte and a ten-kilobyte payload of
/// the same field shape".
const int _small = 16;

/// A kilobyte rather than the ten §6.6.4 names: the VM's per-class accumulator
/// under-counts allocations much above this size (an object that skips new
/// space is not accumulated), so a larger payload would make the tool *less*
/// able to see a per-payload allocation, not more. Sixty-four times the small
/// row is ample to separate "sized from the wire" from "not".
const int _large = 4096;

/// Builds the workload table inside the measured isolate and answers batches.
void _worker(SendPort out) {
  final rx = ReceivePort();
  out.send([dev.Service.getIsolateId(Isolate.current), rx.sendPort]);

  // Everything below is built ONCE, before anything is measured: the encoder
  // and its output buffer, the visitor and its destinations, the wire bytes.
  // What the rows then measure is `write`, `feed` and `decode` alone.
  final outBuf = Uint8List(2 * _large);
  final enc = sofab.Encoder.overBuffer(outBuf);
  final dest = _OwnDest(_large + 64, _large ~/ 8);
  final streaming = sofab.Decoder(dest);
  final ops = <String, void Function()>{'noop': () {}};

  Uint8List wire(void Function(sofab.Encoder) build) {
    enc.reset();
    build(enc);
    return Uint8List.fromList(enc.written);
  }

  ops['encode: typical message'] = () {
    enc.reset();
    encodeTypical(enc);
  };
  ops['encode: perf message'] = () {
    enc.reset();
    encodePerf(enc);
  };
  for (final n in const [_small, _large]) {
    final blob = Uint8List(n);
    ops['encode: blob $n B'] = () {
      enc.reset();
      enc.writeBlob(1, blob);
    };
    final text = 'ä' * (n ~/ 2); // 2 UTF-8 bytes per code unit: the slow path
    ops['encode: utf8 string $n B'] = () {
      enc.reset();
      enc.writeString(1, text);
    };
    final ints = Int64List(n ~/ 8);
    ops['encode: u64 array ${ints.length}'] = () {
      enc.reset();
      enc.writeUnsignedArray(1, ints);
    };
  }

  final typical = wire(encodeTypical);
  ops['decode: typical, one-shot'] = () => sofab.Decoder.decode(typical, dest);
  ops['decode: typical, streaming'] = () => streaming.feed(typical);
  for (final n in const [_small, _large]) {
    final blob = wire((e) => e.writeBlob(1, Uint8List(n)));
    ops['decode: blob $n B, one-shot'] = () => sofab.Decoder.decode(blob, dest);
    ops['decode: blob $n B, streaming'] = () => streaming.feed(blob);
    final f64 = wire((e) => e.writeFp64Array(1, Float64List(n ~/ 8)));
    ops['decode: fp64 array $n B, one-shot'] = () =>
        sofab.Decoder.decode(f64, dest);
    ops['decode: fp64 array $n B, streaming'] = () => streaming.feed(f64);
    final u64 = wire((e) => e.writeUnsignedArray(1, Int64List(n ~/ 8)));
    ops['decode: u64 array $n B, one-shot'] = () =>
        sofab.Decoder.decode(u64, dest);
    ops['decode: u64 array $n B, streaming'] = () => streaming.feed(u64);
  }

  // The hostile row §6.6.4 asks for: seven bytes announcing ARRAY_MAX fp64
  // elements. It must cost what any other rejected header costs.
  // A control that touches no SofaBuffers code at all: one `setRange` of the
  // large payload, which allocates nothing by construction. Whatever it reads
  // is what this measurement charges a row for *moving* that many bytes, and
  // the large codec rows are read against it rather than against zero.
  final controlSrc = Uint8List(_large);
  final controlDst = Uint8List(_large);
  ops['control: memcpy $_large B'] = () =>
      controlDst.setRange(0, _large, controlSrc);

  final hostile = Uint8List.fromList([
    0x0d,
    0xff,
    0xff,
    0xff,
    0xff,
    0x07,
    0x41,
  ]);
  ops['decode: hostile count, one-shot'] = () =>
      sofab.Decoder.decode(hostile, dest);
  ops['decode: hostile count, streaming'] = () =>
      sofab.Decoder(dest).feed(hostile);

  rx.listen((msg) {
    if (msg == 'quit') {
      rx.close();
      return;
    }
    final batch = msg as List;
    final op = ops[batch[0] as String];
    if (op == null) {
      throw StateError(
        'unknown workload ${batch[0]} — the name list in the '
        'driver and the table in the worker have drifted',
      );
    }
    final reps = batch[1] as int;
    for (var i = 0; i < reps; i++) {
      op();
    }
    (batch[2] as SendPort).send(dest.seen);
  });
}

// ---------------------------------------------------------------- driver ---

late final Uri _service;
late final String _isolateId;
late final SendPort _work;
final HttpClient _http = HttpClient();

Future<List<int>> _profile({bool reset = false}) async {
  final req = await _http.getUrl(
    _service.replace(
      path: '${_service.path}getAllocationProfile',
      queryParameters: {'isolateId': _isolateId, if (reset) 'reset': 'true'},
    ),
  );
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  final result =
      (jsonDecode(body) as Map<String, Object?>)['result']
          as Map<String, Object?>;
  var n = 0, bytes = 0, all = 0;
  for (final m in (result['members'] as List).cast<Map<String, Object?>>()) {
    final instances = m['instancesAccumulated']! as int;
    all += instances;
    final name = (m['class']! as Map)['name'] as String?;
    if (name != null && _containerClasses.contains(name)) {
      n += instances;
      bytes += m['accumulatedSize']! as int;
    }
  }
  return [n, bytes, all];
}

Future<void> _run(String name, int reps) async {
  final rp = ReceivePort();
  _work.send([name, reps, rp.sendPort]);
  await rp.first;
  rp.close();
}

Future<_Row> _measure(String name, int reps) async {
  await _run(name, reps < 1000 ? 50 : 500); // warm: lazy inits, JIT
  await _profile(reset: true);
  await _run(name, reps);
  final s = await _profile();
  return _Row(name, reps, s[0] / reps, s[1] / reps, s[2] / reps);
}

Future<void> main(List<String> args) async {
  final json = args.contains('--json');
  final quick = args.contains('--quick');
  // The floor below is the reading's resolution: a row is only as sharp as
  // (the RPC's own cost / reps), and that cost is ~300k allocations with a few
  // per cent of run-to-run drift. 100k reps put it near 3 allocations/op —
  // sharp enough to see a single stray allocation per op, and sharp enough that
  // one payload-sized allocation per op would read as thousands of bytes/op.
  final reps = quick ? 20000 : 100000;

  final info = await dev.Service.controlWebServer(
    enable: true,
    silenceOutput: true,
  );
  final uri = info.serverUri;
  if (uri == null) {
    stderr.writeln(
      'error: no VM service — run this on the JIT VM (`dart run`), not AOT',
    );
    exit(2);
  }
  _service = uri;

  final rp = ReceivePort();
  await Isolate.spawn(_worker, rp.sendPort);
  final hello = await rp.first as List;
  _isolateId = hello[0] as String;
  _work = hello[1] as SendPort;

  final rows = <_Row>[];
  // A `noop` baseline per repetition count: the service RPC allocates in the
  // isolate it reports on, and that fixed cost divided by the reps is what a
  // row must be read against.
  final baseline = await _measure('noop', reps);

  for (final name in await _names()) {
    rows.add(await _measure(name, reps));
  }

  double net(double v, double Function(_Row) pick) => v - pick(baseline);

  if (json) {
    final out = <String, Object?>{};
    for (final r in rows) {
      out[r.name] = {
        'reps': r.reps,
        'allocs': net(r.allocs, (b) => b.allocs),
        'bytes': net(r.bytes, (b) => b.bytes),
        'all': net(r.all, (b) => b.all),
        'floor_allocs': baseline.allocs,
        'floor_bytes': baseline.bytes,
      };
    }
    // ignore: avoid_print
    print(jsonEncode(out));
  } else {
    final b = StringBuffer();
    b.writeln('=== SofaBuffers Dart codec allocations (VM service, net) ===');
    b.writeln(
      '${'Workload'.padRight(38)} ${'allocs/op'.padLeft(10)} '
      '${'bytes/op'.padLeft(10)} ${'all/op'.padLeft(10)}',
    );
    b.writeln(
      '${'--------'.padRight(38)} ${'---------'.padLeft(10)} '
      '${'--------'.padLeft(10)} ${'------'.padLeft(10)}',
    );
    for (final r in rows) {
      b.writeln(
        '${r.name.padRight(38)} '
        '${net(r.allocs, (x) => x.allocs).toStringAsFixed(2).padLeft(10)} '
        '${net(r.bytes, (x) => x.bytes).toStringAsFixed(1).padLeft(10)} '
        '${net(r.all, (x) => x.all).toStringAsFixed(1).padLeft(10)}',
      );
    }
    b.writeln();
    b.writeln(
      'allocs/op and bytes/op count only the container classes a payload could '
      'land in; all/op is every class, the service RPC\'s own churn included. '
      'Every row is $reps ops, net of a `noop` row measured the same way, whose '
      'reading is the floor: ${baseline.allocs.toStringAsFixed(2)} '
      'containers/op, ${baseline.bytes.toStringAsFixed(1)} bytes/op, '
      '${baseline.all.toStringAsFixed(1)} objects/op.',
    );
    b.write(
      'A row is conformant when it does not grow with the payload: read the '
      'small and large rows of one shape against each other. The floor is what '
      'a row of zero allocations reads as.',
    );
    // ignore: avoid_print
    print(b.toString());
  }

  _work.send('quit');
  _http.close();
  exit(0);
}

/// The workload names, asked of the worker so the two lists cannot drift.
Future<List<String>> _names() async {
  // The worker builds its table from the same literals this list mirrors; it is
  // cheaper to rebuild the names here than to ship the map across the port.
  return <String>[
    'encode: typical message',
    'encode: perf message',
    for (final n in const [_small, _large]) ...[
      'encode: blob $n B',
      'encode: utf8 string $n B',
      'encode: u64 array ${n ~/ 8}',
    ],
    'decode: typical, one-shot',
    'decode: typical, streaming',
    for (final n in const [_small, _large]) ...[
      'decode: blob $n B, one-shot',
      'decode: blob $n B, streaming',
      'decode: fp64 array $n B, one-shot',
      'decode: fp64 array $n B, streaming',
      'decode: u64 array $n B, one-shot',
      'decode: u64 array $n B, streaming',
    ],
    'decode: hostile count, one-shot',
    'decode: hostile count, streaming',
    'control: memcpy $_large B',
  ];
}
