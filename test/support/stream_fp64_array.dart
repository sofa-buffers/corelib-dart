// Support program for `test/fixlen_array_peak_memory_test.dart` — NOT a test
// file itself (it is outside the `*_test.dart` glob on purpose).
//
// Streams one large `array<fp64>` field into a [sofab.Decoder] under a VM heap
// cap chosen so that the message fits **once** and not twice: the decoded
// `Float64List` is the only thing that may be the size of the payload. A
// decoder that stages the wire bytes in a second, payload-sized scratch buffer
// before converting them into the result list needs twice the room and dies
// with an out-of-memory error instead of printing `ok`.
//
// The payload bytes are fed from one small, reused chunk, so the *input* side
// contributes nothing to the peak — what the cap measures is decoder state.
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;

/// Elements in the streamed array — 3_000_000 × 8 B = 24 MiB of payload.
const int elemCount = 3000000;
const int chunkSize = 64 * 1024;

class _Sink extends sofab.MessageVisitor {
  Float64List? got;
  @override
  void onFp64Array(int id, Float64List value) => got = value;
}

void main() {
  final sink = _Sink();
  // 3,000,000 elements is over the receiver's default array cap, which is a
  // deployment number rather than a format one (CORELIB_PLAN §6.2.1): a
  // receiver that means to take a 24 MiB array says so.
  final dec = sofab.Decoder(
    sink,
    limits: const sofab.DecoderLimits(maxArrayCount: elemCount),
  );

  // Field 1, wire type array_fixlen; element_count; fixlen_word (fp64 → 8 B).
  final header = BytesBuilder();
  header.add(_varint((1 << 3) | 5)); // id 1, WireType.arrayFixlen
  header.add(_varint(elemCount));
  header.add(_varint((8 << 3) | 1)); // fixlen_word: len 8, subtype fp64
  var st = dec.feed(header.takeBytes());
  if (st != sofab.DecodeStatus.incomplete) throw StateError('header: $st');

  // 24 MiB of payload from one reused 64 KiB chunk: element i is the double
  // `i % 251`, so the receiver can verify the bytes landed in the right slots.
  final chunk = Uint8List(chunkSize);
  final view = ByteData.sublistView(chunk);
  var total = elemCount * 8;
  var elem = 0;
  while (total > 0) {
    final n = total < chunkSize ? total : chunkSize;
    for (var o = 0; o < n; o += 8) {
      view.setFloat64(o, (elem++ % 251).toDouble(), Endian.little);
    }
    st = dec.feed(n == chunkSize ? chunk : Uint8List.sublistView(chunk, 0, n));
    total -= n;
  }
  if (st != sofab.DecodeStatus.complete) throw StateError('payload: $st');

  final got = sink.got!;
  if (got.length != elemCount) throw StateError('length ${got.length}');
  for (final i in [0, 1, 250, 251, chunkSize ~/ 8, elemCount - 1]) {
    if (got[i] != (i % 251).toDouble()) throw StateError('elem $i = ${got[i]}');
  }
  // ignore: avoid_print
  print('ok');
}

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (x >= 0x80) {
    out.add((x & 0x7F) | 0x80);
    x >>>= 7;
  }
  out.add(x);
  return out;
}
