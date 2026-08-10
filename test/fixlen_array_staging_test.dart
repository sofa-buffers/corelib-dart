import 'dart:io';
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// Streaming fixlen-array decode stages the payload **in the result list**
/// (corelib-dart#43).
///
/// A fixlen array's payload is, byte for byte, the little-endian image of the
/// `Float32List`/`Float64List` it decodes into. The streaming decoder used to
/// allocate a second, payload-sized scratch buffer, fill that, and then copy the
/// whole thing into the typed list — 2× the peak memory and every element
/// touched twice, on a **maxspeed** port whose one-shot path never did this.
/// It now allocates the result list only and feeds the arriving bytes straight
/// into its own storage.
///
/// The memory half of that claim cannot be asserted from inside the isolate
/// doing the decoding, so it is measured the way the VM makes measurable: a
/// child process with an old-generation heap cap sized to hold the payload
/// **once** and not twice ([_capMiB] vs. the 24 MiB decoded by
/// `test/support/stream_fp64_array.dart`). Staging in a second buffer exhausts
/// that heap in `Decoder._stepArrFixWord`; staging in the result list fits with
/// room to spare. The correctness half — that bytes still land in the right
/// slots, bit-exactly, across arbitrary chunk boundaries — is asserted directly.
void main() {
  group('#43 — a streamed fixlen array is allocated once', () {
    test(
      '24 MiB of fp64 elements decode under a $_capMiB MiB heap cap',
      () {
        final script = File(_supportScript);
        expect(
          script.existsSync(),
          isTrue,
          reason: 'run `dart test` from the package root ($_supportScript)',
        );
        final r = Process.runSync(Platform.resolvedExecutable, [
          '--old_gen_heap_size=$_capMiB',
          'run',
          _supportScript,
        ]);
        expect(
          r.exitCode,
          0,
          reason:
              'the payload was staged twice — heap cap $_capMiB MiB, payload '
              '24 MiB\nstdout: ${r.stdout}\nstderr: ${r.stderr}',
        );
        expect((r.stdout as String).trim(), 'ok');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    // The one-shot path is the reference: same bytes, same elements, whatever
    // the chunking. Staging in the result list must not change a single bit —
    // including the payload bits of a signaling NaN (CORELIB_PLAN §4.6/§6.5),
    // which no longer pass through a `double` conversion at all.
    for (final chunk in const [1, 3, 7, 8, 64]) {
      test('fp64 elements are bit-exact fed $chunk byte(s) at a time', () {
        final bits = <int>[
          0x0000000000000000, // +0.0
          0x8000000000000000, // −0.0
          0x3FF0000000000000, // 1.0
          0xC05EDD2F1A9FBE77, // −123.456…
          0x7FF0000000000000, // +inf
          0x7FF0000000000001, // signaling NaN, payload 1
          0xFFF8000000000001, // negative quiet NaN with payload
          0x7FEFFFFFFFFFFFFF, // max finite
        ];
        final msg = _fp64Array(1, bits);

        final one = _Collect();
        expect(sofab.Decoder.decode(msg, one), sofab.DecodeStatus.complete);
        expect(_bitsOf(one.f64!), bits);

        final streamed = _Collect();
        expect(
          _feedInChunks(msg, streamed, chunk),
          sofab.DecodeStatus.complete,
        );
        expect(_bitsOf(streamed.f64!), bits);
      });

      test('fp32 elements are bit-exact fed $chunk byte(s) at a time', () {
        final bits = <int>[
          0x00000000, // +0.0
          0x80000000, // −0.0
          0x3F800000, // 1.0
          0xC2F6E979, // −123.456
          0x7F800000, // +inf
          0x7F800001, // signaling NaN, payload 1
          0xFFC00001, // negative quiet NaN with payload
          0x7F7FFFFF, // max finite
        ];
        final msg = _fp32Array(2, bits);

        final one = _Collect();
        expect(sofab.Decoder.decode(msg, one), sofab.DecodeStatus.complete);
        expect(_bitsOf(one.f32!), bits);

        final streamed = _Collect();
        expect(
          _feedInChunks(msg, streamed, chunk),
          sofab.DecodeStatus.complete,
        );
        expect(_bitsOf(streamed.f32!), bits);
      });
    }

    // The staging buffer is now the previous array's storage until the next
    // field replaces it, so decoding several arrays in a row must not let a
    // later field write into an already-delivered list.
    test('back-to-back arrays do not share storage', () {
      final out = BytesBuilder();
      out.add(_fp64Array(1, const [0x3FF0000000000000, 0x4000000000000000]));
      out.add(_fp64Array(2, const [0x4008000000000000, 0x4010000000000000]));
      out.add(_fp32Array(3, const [0x3F800000, 0x40000000]));
      final msg = out.takeBytes();

      final kept = <List<int>>[];
      final v = _Keep(kept);
      var st = sofab.DecodeStatus.incomplete;
      for (final b in msg) {
        st = v.dec.feed([b]);
      }
      expect(st, sofab.DecodeStatus.complete);
      expect(kept, [
        [0x3FF0000000000000, 0x4000000000000000],
        [0x4008000000000000, 0x4010000000000000],
        [0x3F800000, 0x40000000],
      ]);
    });

    test('an empty fixlen array still delivers an empty list', () {
      final v = _Collect();
      expect(
        _feedInChunks(_fp64Array(1, const []), v, 1),
        sofab.DecodeStatus.complete,
      );
      expect(v.f64, isEmpty);
    });

    // A skipped array allocates nothing at all — neither the staging change nor
    // the bulk move may depend on a result list that is never built.
    for (final chunk in const [3, 16]) {
      test('a skipped fixlen array is consumed in $chunk-byte chunks', () {
        final v = _Skip();
        expect(
          _feedInChunks(_fp64Array(1, const [0x3FF0000000000000, 0]), v, chunk),
          sofab.DecodeStatus.complete,
        );
        expect(v.f64, isNull);
      });
    }

    // The bulk move also serves a chunk that is a plain `List<int>` rather than
    // a `Uint8List`, where the per-byte path masked each byte to 8 bits — the
    // move has to mask identically.
    test('a List<int> chunk decodes to the same bytes, masked', () {
      final bits = <int>[0x7FF0000000000001, 0x3FF0000000000000, 0];
      final msg = _fp64Array(1, bits);
      final wide = <int>[for (final b in msg) b + 0x100]; // must mask back
      final v = _Collect();
      final dec = sofab.Decoder(v);
      var st = sofab.DecodeStatus.incomplete;
      for (var i = 0; i < wide.length; i += 16) {
        st = dec.feed(wide.sublist(i, (i + 16).clamp(0, wide.length)));
      }
      expect(st, sofab.DecodeStatus.complete);
      expect(_bitsOf(v.f64!), bits);
    });
  });
}

/// Heap cap for the child decode, in MiB: comfortably above the 24 MiB payload
/// the support program streams, comfortably below the 48 MiB a double-staging
/// decoder needs.
const int _capMiB = 40;
const String _supportScript = 'test/support/stream_fp64_array.dart';

class _Collect extends sofab.MessageVisitor {
  Float64List? f64;
  Float32List? f32;
  @override
  void onFp64Array(int id, Float64List value) => f64 = value;
  @override
  void onFp32Array(int id, Float32List value) => f32 = value;
}

/// Keeps every delivered array, as raw bit patterns, so a later field writing
/// into an earlier field's storage would show up as a changed earlier row.
class _Keep extends sofab.MessageVisitor {
  _Keep(this.kept) {
    dec = sofab.Decoder(this);
  }
  final List<List<int>> kept;
  late final sofab.Decoder dec;
  @override
  void onFp64Array(int id, Float64List value) => kept.add(_bitsOf(value));
  @override
  void onFp32Array(int id, Float32List value) => kept.add(_bitsOf(value));
}

/// Declares no fields at all, so every field is skipped (`_read == false`).
class _Skip extends _Collect {
  @override
  bool shouldRead(int id, int type) => false;
}

sofab.DecodeStatus _feedInChunks(
  Uint8List msg,
  sofab.MessageVisitor v,
  int chunkSize,
) {
  final dec = sofab.Decoder(v);
  var st = sofab.DecodeStatus.incomplete;
  for (var i = 0; i < msg.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, msg.length);
    st = dec.feed(Uint8List.sublistView(msg, i, end));
  }
  return st;
}

List<int> _bitsOf(List<double> values) {
  if (values is Float32List) {
    final bd = ByteData.sublistView(values);
    return [
      for (var i = 0; i < values.length; i++)
        bd.getUint32(i * 4, Endian.little),
    ];
  }
  final bd = ByteData.sublistView(values as Float64List);
  return [
    for (var i = 0; i < values.length; i++) bd.getUint64(i * 8, Endian.little),
  ];
}

Uint8List _fp64Array(int id, List<int> bits) {
  final payload = Uint8List(bits.length * 8);
  final bd = ByteData.sublistView(payload);
  for (var i = 0; i < bits.length; i++) {
    bd.setUint64(i * 8, bits[i], Endian.little);
  }
  return _arrayMessage(id, bits.length, (8 << 3) | 1, payload);
}

Uint8List _fp32Array(int id, List<int> bits) {
  final payload = Uint8List(bits.length * 4);
  final bd = ByteData.sublistView(payload);
  for (var i = 0; i < bits.length; i++) {
    bd.setUint32(i * 4, bits[i], Endian.little);
  }
  return _arrayMessage(id, bits.length, (4 << 3) | 0, payload);
}

Uint8List _arrayMessage(int id, int count, int fixlenWord, Uint8List payload) {
  final out = BytesBuilder();
  out.add(_varint((id << 3) | 5)); // wire type array_fixlen
  out.add(_varint(count));
  out.add(_varint(fixlenWord));
  out.add(payload);
  return out.takeBytes();
}

List<int> _varint(int value) {
  final out = <int>[];
  var x = value;
  while (x >= 0x80) {
    out.add((x & 0x7F) | 0x80);
    x >>>= 7;
  }
  out.add(x);
  return out;
}
