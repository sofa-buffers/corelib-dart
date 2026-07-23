import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Header-callback tests for MESSAGE_SPEC §5.2 anti-folding (Crucible F-0032).
///
/// The corelib exposes [sofab.MessageVisitor.onArrayBegin] /
/// [sofab.MessageVisitor.onFixlenHeader], fired the instant the count / length
/// word is read — *before* the element / payload and *before* the truncation
/// check. A schema-bound visitor (as the generator emits) rejects
/// `count > N` / `length > maxlen` there, so the resulting INVALID **dominates**
/// a truncated tail: a message that is both malformed and cut short is INVALID,
/// never INCOMPLETE. The corelib itself carries no verdict logic — it only calls
/// the hooks; the generated `inv ? invalid : status` combination is modelled
/// here by [_verdict].
void main() {
  // A stand-in for a generated, schema-bound visitor: rejects over-count arrays
  // and over-maxlen strings/blobs at the header, and records call order so we can
  // assert the header fires before the assembled-value callback.
  //
  // arrayMax/strMax: id -> schema bound N / maxlen L.
  SchemaVisitor mk({
    Map<int, int> arrayMax = const {},
    Map<int, int> strMax = const {},
    Set<int> skipIds = const {},
  }) => SchemaVisitor(arrayMax: arrayMax, strMax: strMax, skipIds: skipIds);

  // Runs the same bytes through both decode paths — one-shot contiguous, and the
  // streaming state machine fed one byte at a time (worst-case suspend/resume) —
  // and asserts they agree, returning the shared verdict.
  sofab.DecodeStatus bothPaths(String hex, SchemaVisitor Function() make) {
    final bytes = hexToBytes(hex);

    final contig = make();
    final cSt = _verdict(contig, sofab.Decoder.decode(bytes, contig));

    final stream = make();
    final dec = sofab.Decoder(stream);
    var last = sofab.DecodeStatus.complete;
    for (final b in bytes) {
      last = dec.feed([b]);
    }
    if (bytes.isEmpty) last = dec.feed(const []);
    final sSt = _verdict(stream, last);

    expect(sSt, cSt, reason: 'streaming and contiguous paths must agree');
    return cSt;
  }

  group('int array over-count (issue #18 reproduction, id 15 = header 0x7b)', () {
    SchemaVisitor make() => mk(arrayMax: {15: 4});

    test('count 5 (>4), complete → INVALID', () {
      expect(bothPaths('7b05' '0102030405', make), sofab.DecodeStatus.invalid);
    });

    test('count 6 (>4), then EOF → INVALID (was INCOMPLETE)', () {
      expect(bothPaths('7b06' '0102', make), sofab.DecodeStatus.invalid);
    });

    test('count 4 (==bound), then EOF → INCOMPLETE (clean truncation)', () {
      final v = mk(arrayMax: {15: 4});
      expect(bothPaths('7b04' '0102', () => mk(arrayMax: {15: 4})),
          sofab.DecodeStatus.incomplete);
      // And no spurious INVALID flag was raised.
      sofab.Decoder.decode(hexToBytes('7b04' '0102'), v);
      expect(v.inv, isFalse);
    });

    test('count 4, all present → COMPLETE', () {
      expect(bothPaths('7b04' '01020304', make), sofab.DecodeStatus.complete);
    });
  });

  test('onArrayBegin fires before the assembled-array callback', () {
    final v = mk(arrayMax: {15: 99});
    sofab.Decoder.decode(hexToBytes('7b04' '01020304'), v);
    expect(v.order, ['begin:15:4', 'arr:15']);
  });

  group('string over-maxlen (id 5 = header 0x2a, subtype 2)', () {
    // maxlen 3. length word for a string of L bytes = (L<<3)|2.
    SchemaVisitor make() => mk(strMax: {5: 3});

    test('length 5 (>3), complete → INVALID', () {
      // 0x2a header, word (5<<3)|2 = 0x2a, then 5 bytes "abcde".
      expect(bothPaths('2a2a' '6162636465', make), sofab.DecodeStatus.invalid);
    });

    test('length 5 (>3), payload cut → INVALID (was INCOMPLETE)', () {
      expect(bothPaths('2a2a' '6162', make), sofab.DecodeStatus.invalid);
    });

    test('length 3 (==maxlen), payload cut → INCOMPLETE', () {
      // word (3<<3)|2 = 0x1a, only 2 of 3 bytes.
      expect(bothPaths('2a1a' '6162', make), sofab.DecodeStatus.incomplete);
    });
  });

  test('onFixlenHeader carries the exact subtype and length', () {
    final v = mk(strMax: {5: 99});
    sofab.Decoder.decode(hexToBytes('2a1a' '616263'), v); // string, len 3
    expect(v.order, ['fix:5:${sofab.FixlenType.string}:3', 'str:5']);
  });

  group('fixlen (fp32) array over-count (id 7 = header 0x3d, subtype 0)', () {
    SchemaVisitor make() => mk(arrayMax: {7: 2});

    test('count 3 (>2), payload cut → INVALID (was INCOMPLETE)', () {
      // 0x3d header, count 3, word (4<<3)|0 = 0x20, then a short payload.
      expect(bothPaths('3d03' '20' '00000000', make),
          sofab.DecodeStatus.invalid);
    });

    test('count 2 (==bound), payload cut → INCOMPLETE', () {
      // 8 bytes expected (2 * fp32), only 4 present.
      expect(bothPaths('3d02' '20' '00000000', () => mk(arrayMax: {7: 2})),
          sofab.DecodeStatus.incomplete);
    });
  });

  test('skipped over-count field never fires the header hook', () {
    // id 15 skipped: shouldRead=false, so no onArrayBegin, no INVALID — a skipped
    // subtree is not schema-validated (CORELIB_PLAN §6.4).
    final v = mk(arrayMax: {15: 4}, skipIds: {15});
    final st = sofab.Decoder.decode(hexToBytes('7b05' '0102030405'), v);
    expect(v.order, isEmpty);
    expect(v.inv, isFalse);
    expect(st, sofab.DecodeStatus.complete);
  });
}

sofab.DecodeStatus _verdict(SchemaVisitor v, sofab.DecodeStatus st) =>
    v.inv ? sofab.DecodeStatus.invalid : st;

class SchemaVisitor extends sofab.MessageVisitor {
  SchemaVisitor({
    this.arrayMax = const {},
    this.strMax = const {},
    this.skipIds = const {},
  });
  final Map<int, int> arrayMax; // id -> schema element-count bound N
  final Map<int, int> strMax; // id -> schema byte-length bound (maxlen)
  final Set<int> skipIds;
  bool inv = false; // sticky INVALID flag, as the generated visitor keeps
  final List<String> order = <String>[];

  @override
  bool shouldRead(int id, int type) => !skipIds.contains(id);

  @override
  void onArrayBegin(int id, int count) {
    order.add('begin:$id:$count');
    final n = arrayMax[id];
    if (n != null && count > n) inv = true;
  }

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    order.add('fix:$id:$subtype:$length');
    final l = strMax[id];
    if (l != null && length > l) inv = true;
  }

  @override
  void onUnsignedArray(int id, Int64List values) => order.add('arr:$id');
  @override
  void onSignedArray(int id, Int64List values) => order.add('arr:$id');
  @override
  void onFp32Array(int id, Float32List values) => order.add('arr:$id');
  @override
  void onFp64Array(int id, Float64List values) => order.add('arr:$id');
  @override
  void onString(int id, String value) => order.add('str:$id');
  @override
  void onBlob(int id, Uint8List value) => order.add('blb:$id');
}
