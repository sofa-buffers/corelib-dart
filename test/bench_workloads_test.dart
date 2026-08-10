// The BENCH_SPEC datasets, checked the way BENCH_SPEC asks for them to be
// checked: by their **encoded size**. "The encoded size of the `perf` message
// (170 bytes on every implementation) is a quick parity check: if your `perf`
// prints a different `message size`, your encoding diverges" — and the same is
// said of the 1,000,005-byte `blob 1MB` message and of `composite`.
//
// A benchmark is only comparable across ports if it is measuring the same
// bytes, so those sizes are as much a conformance property as anything in
// `test_vectors.json`, and belong in the suite rather than in a comment inside
// a tool nobody runs in CI's fast leg. This also keeps the workloads honest in
// the other direction: every dataset is round-tripped through the surface the
// benchmark drives it with — one-shot, chunk-fed, and skip-everything — so a
// row cannot start printing a number for work that does not actually decode.

import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import '../bench/workloads.dart';

/// Feeds [bytes] to a streaming decoder in [chunk]-byte pieces — how the
/// `decode: blob 1MB` row is driven.
sofab.DecodeStatus _feedChunked(
  Uint8List bytes,
  sofab.MessageVisitor visitor, {
  required int chunk,
}) {
  final dec = sofab.Decoder(visitor);
  var status = sofab.DecodeStatus.incomplete;
  for (var off = 0; off < bytes.length; off += chunk) {
    final end = off + chunk < bytes.length ? off + chunk : bytes.length;
    status = dec.feed(Uint8List.sublistView(bytes, off, end));
  }
  return status;
}

void main() {
  group('BENCH_SPEC dataset parity sizes', () {
    test('the `perf` message is 170 bytes on every implementation', () {
      expect(encodedSize(encodePerf), 170);
    });

    test('the `typical` message encodes to its documented ~37 bytes', () {
      expect(encodedSize(encodeTypical), 37);
    });

    test(
      '`blob 1MB` is 1,000,005 bytes: 1 header + 4 fixlen_word + payload',
      () {
        final blob = buildBlob();
        expect(blob.length, blobLen);
        expect(encodedSize((e) => encodeBlob(e, blob)), blobEncodedSize);
        expect(blobEncodedSize, blobLen + 5);
      },
    );

    test('`composite` encodes to its cross-port size', () {
      expect(encodedSize(encodeComposite), compositeEncodedSize);
    });
  });

  group('BENCH_SPEC dataset content', () {
    test('the blob payload is the low byte of the u64-array constant', () {
      final blob = buildBlob();
      for (final i in const [0, 1, 2, 999, 12345, blobLen - 1]) {
        expect(blob[i], (i * 0x9E3779B97F4A7C15) & 0xFF, reason: 'b[$i]');
      }
    });

    test('composite omits the all-default field 4 and keeps field 130', () {
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      final ids = <int>[];
      final probe = _TopLevelIds(ids);
      expect(sofab.Decoder.decode(wire, probe), sofab.DecodeStatus.complete);
      // ids 1, 2, 3 and 130 — never 4, whose value equals its declared default.
      expect(ids, [1, 2, 3, 130]);
    });

    test('composite field 1 is a wrapper array of 64 elements', () {
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      final probe = _WrapperElements();
      expect(sofab.Decoder.decode(wire, probe), sofab.DecodeStatus.complete);
      expect(probe.elements.length, 64);
      expect(probe.elements.first, 'item-0');
      expect(probe.elements.last, 'item-63');
    });

    test('composite field 2 is 320 UTF-8 bytes over all four widths', () {
      expect(compositeText.runes.length, 4);
      final probe = _StringLengths();
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      expect(sofab.Decoder.decode(wire, probe), sofab.DecodeStatus.complete);
      expect(probe.byId[2], 320);
    });
  });

  group('the surfaces the rows drive', () {
    test('blob 1MB one-shot: a hand-sized caller buffer, no sink', () {
      final blob = buildBlob();
      // BENCH_SPEC: the one-shot buffer is sized by hand, not from MAX_SIZE.
      final enc = sofab.Encoder.overBuffer(Uint8List(blobEncodedSize));
      encodeBlob(enc, blob);
      enc.flush();
      expect(enc.written.length, blobEncodedSize);
    });

    test('blob 1MB streaming: a 4096-byte buffer plus a discarding sink', () {
      final blob = buildBlob();
      final sink = DiscardSink();
      final enc = sofab.Encoder(sink.add, buffer: Uint8List(blobChunk));
      encodeBlob(enc, blob);
      enc.flush();
      // Every byte reached the sink, in ~245 flushes, and none was retained.
      expect(sink.bytes, blobEncodedSize);
      expect(sink.flushes, greaterThan(blobEncodedSize ~/ blobChunk));
    });

    test('blob 1MB decode: fed in 4096-byte chunks', () {
      final blob = buildBlob();
      final wire = sofab.Encoder.encodeToBytes(
        (e) => encodeBlob(e, blob),
        bufferSize: 64 * 1024,
      );
      final v = CountingVisitor();
      expect(
        _feedChunked(wire, v, chunk: blobChunk),
        sofab.DecodeStatus.complete,
      );
      expect(v.fields, 1);
    });

    test('composite round-trips on the one-shot surface', () {
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      final v = CountingVisitor();
      expect(sofab.Decoder.decode(wire, v), sofab.DecodeStatus.complete);
      // 64 wrapper elements + the long string + the nested u/s pair + id 130.
      expect(v.fields, 68);
    });

    test('composite skip-all walks the message and materializes nothing', () {
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      final skip = SkipAllVisitor();
      expect(sofab.Decoder.decode(wire, skip), sofab.DecodeStatus.complete);
      // Every top-level field was offered and refused; the sub-sequences were
      // declined at their start, so nothing inside them was ever offered.
      expect(skip.skipped, greaterThan(0));
      final read = CountingVisitor();
      expect(sofab.Decoder.decode(wire, read), sofab.DecodeStatus.complete);
      expect(skip.skipped, lessThan(read.fields));
    });

    test('composite decodes identically when fed one byte at a time', () {
      final wire = sofab.Encoder.encodeToBytes(encodeComposite);
      final v = CountingVisitor();
      expect(_feedChunked(wire, v, chunk: 1), sofab.DecodeStatus.complete);
      expect(v.fields, 68);
    });
  });
}

/// Records the ids of the **top-level** fields, ignoring everything nested.
class _TopLevelIds extends sofab.MessageVisitor {
  _TopLevelIds(this.ids);
  final List<int> ids;
  int _depth = 0;

  void _note(int id) {
    if (_depth == 0) ids.add(id);
  }

  @override
  void onUnsigned(int id, int value) => _note(id);
  @override
  void onSigned(int id, int value) => _note(id);
  @override
  void onString(int id, String value) => _note(id);
  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    _note(id);
    _depth++;
    return this;
  }

  @override
  void onSequenceEnd() => _depth--;
}

/// Collects the elements of the wrapper array in field 1.
class _WrapperElements extends sofab.MessageVisitor {
  final List<String> elements = <String>[];
  bool _inWrapper = false;

  @override
  void onString(int id, String value) {
    if (_inWrapper) elements.add(value);
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    if (id == 1) _inWrapper = true;
    return this;
  }

  @override
  void onSequenceEnd() => _inWrapper = false;
}

/// Records the UTF-8 byte length of every top-level string by field id.
class _StringLengths extends sofab.MessageVisitor {
  final Map<int, int> byId = <int, int>{};
  int _depth = 0;

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (_depth == 0) byId[id] = bytes.length;
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    _depth++;
    return this;
  }

  @override
  void onSequenceEnd() => _depth--;
}
