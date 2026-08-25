import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The codec holds no receiver-side limits (CORELIB_PLAN §6.2.1).
///
/// Every receiver MUST carry the three `max_dyn_*` limits, and *"there is no
/// unset state and no unlimited mode"* — but the numbers are not the codec's:
///
/// > **The numbers and the allocation are not the codec's.** The limits come
/// > from generated code, which knows the schema and the target … What the codec
/// > contributes is the report and the category: it surfaces the count at the
/// > count/length header; for a sequence array it surfaces the index of the
/// > element in hand; the visitor decides. The codec never invents a limit of
/// > its own and never clamps to one.
///
/// So this decoder has no cap state, no `DecoderLimits`, and the library defines
/// no `max_dyn_*` default constant to fall back on. What it guarantees instead
/// is that the consumer is told **in time**: the count or length reaches the
/// visitor at the header, before a destination is asked for, on both decode
/// surfaces and at every chunk boundary.
///
/// The case that motivates the whole file: seven bytes declaring an
/// `array<fp64>` of `ARRAY_MAX` elements. Against a visitor that neither caps
/// nor declines, that is 17 GB — which is why the cap has to be *somewhere*, and
/// why "somewhere" has to be a place that knows whether the field is even this
/// consumer's.
void main() {
  /// The seven bytes: field 1, wire type array_fixlen, `element_count` =
  /// ARRAY_MAX, `fixlen_word` = fp64 (8 bytes/element).
  final bomb = hexToBytes('0dffffffff0741');

  group('the codec reports the header and judges nothing', () {
    test(
      'the count reaches the visitor before any destination is asked for',
      () {
        final v = _Recorder();
        expect(sofab.Decoder.decode(bomb, v), sofab.DecodeStatus.incomplete);
        expect(v.begins, [
          [1, sofab.ArrayKind.fp64, sofab.arrayMax],
        ]);
        expect(v.dests, isEmpty, reason: 'declined, so nothing was sized');
      },
    );

    test('the streaming surface reports the same header, byte at a time', () {
      final v = _Recorder();
      final dec = sofab.Decoder(v);
      var st = sofab.DecodeStatus.complete;
      for (final b in bomb) {
        st = dec.feed([b]);
      }
      expect(st, sofab.DecodeStatus.incomplete);
      expect(v.begins, [
        [1, sofab.ArrayKind.fp64, sofab.arrayMax],
      ]);
      // The streaming surface DOES ask — it cannot know how many bytes are
      // still coming, so it cannot refute the count the way the one-shot walker
      // above did. Declining is what bounds it here, and nothing was sized.
      expect(v.dests, [1]);
      expect(v.done, isEmpty);
    });

    test('a string length reaches it the same way', () {
      // id 0, fixlen, fixlen_word = (0x1FFFFFFE << 3) | string — a string
      // announcing half a gigabyte, with no payload behind it.
      final v = _Recorder();
      expect(
        sofab.Decoder.decode(hexToBytes('02f2ffffff0f'), v),
        sofab.DecodeStatus.incomplete,
      );
      expect(v.headers, [
        [0, sofab.FixlenType.string, 0x1FFFFFFE],
      ]);
      expect(v.dests, isEmpty, reason: 'the input refutes the length outright');
    });

    test('no format ceiling was retired with the caps', () {
      // ARRAY_MAX, FIXLEN_MAX, ID_MAX and MAX_DEPTH are facts of the format
      // (§6.2), not deployment policy, and they stay in the codec: a count with
      // bit 63 set is INVALID whatever any visitor thinks.
      expect(
        sofab.Decoder.decode(hexToBytes('03ffffffffffffffffff01'), _Recorder()),
        sofab.DecodeStatus.invalid,
      );
    });
  });

  group('the visitor decides, and its verdict is the outcome', () {
    test('a capping consumer refuses the bomb at the header', () {
      for (final drive in [_oneShot, _byteAtATime]) {
        final v = _Capped(maxArrayCount: 4);
        expect(drive(bomb, v), sofab.DecodeStatus.limitExceeded);
        expect(v.dests, isEmpty, reason: 'refused before the allocation');
      }
    });

    test('an integer array count and a string length, likewise', () {
      // id 0, array_unsigned, count = ARRAY_MAX.
      expect(
        _oneShot(hexToBytes('03ffffffff07'), _Capped(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(
        _byteAtATime(hexToBytes('03ffffffff07'), _Capped(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      // id 0, fixlen, string of FIXLEN_MAX bytes.
      expect(
        _oneShot(hexToBytes('02f2ffffff0f'), _Capped(maxStringLen: 8)),
        sofab.DecodeStatus.limitExceeded,
      );
      // ... and the blob twin.
      expect(
        _oneShot(hexToBytes('02fbffffff0f'), _Capped(maxBlobLen: 8)),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('the verdict is terminal and stays limitExceeded', () {
      final dec = sofab.Decoder(_Capped(maxArrayCount: 4));
      expect(dec.feed(bomb), sofab.DecodeStatus.limitExceeded);
      expect(dec.feed(hexToBytes('00')), sofab.DecodeStatus.limitExceeded);
    });

    test('a cap breach is not INVALID, and is told apart from one', () {
      // Well-formed bytes over a cap → limitExceeded; malformed bytes →
      // invalid. §6.2.1 forbids folding the first into the second, and §6.3
      // requires the caller to be able to tell them apart.
      expect(
        _oneShot(bomb, _Capped(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      // fixlen_word with a reserved subtype (0x4) is malformed, whatever any
      // cap says.
      expect(
        _oneShot(hexToBytes('0224'), _Capped(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test('a payload under the cap still decodes', () {
      final v = _Capped(maxStringLen: 8);
      expect(
        sofab.Decoder.decode(
          Uint8List.fromList([0x02, 0x1a, 0x61, 0x62, 0x63]),
          v,
        ),
        sofab.DecodeStatus.complete,
      );
      expect(v.strings, ['abc']);
    });
  });

  group('a field nothing will read is bounded by not being read', () {
    test('a declined id is never capped, however large it claims to be', () {
      // §6.2.1: "A skipped field is never capped … a decode that steps over an
      // over-cap field it was never going to read stays COMPLETE." Here the
      // outcome is the truncation, because the bytes end mid-array.
      final v = _Capped(maxArrayCount: 4, skipIds: const {1});
      expect(_oneShot(bomb, v), sofab.DecodeStatus.incomplete);
      expect(
        _byteAtATime(bomb, _Capped(maxArrayCount: 4, skipIds: const {1})),
        sofab.DecodeStatus.incomplete,
      );
    });

    test('declining the destination is the other half of the same answer', () {
      // A consumer with no arm for a field allocates nothing for it, which is
      // a stronger guarantee than any cap: not "at most N elements" but none.
      // This is the shape generated code uses for an id its schema does not
      // declare — [_Recorder] returns null from both destination hooks.
      final v = _Recorder();
      expect(_oneShot(bomb, v), sofab.DecodeStatus.incomplete);
      expect(v.dests, isEmpty);
      expect(v.done, isEmpty, reason: 'nothing was delivered either');
    });
  });
}

sofab.DecodeStatus _oneShot(Uint8List bytes, sofab.MessageVisitor v) =>
    sofab.Decoder.decode(bytes, v);

sofab.DecodeStatus _byteAtATime(Uint8List bytes, sofab.MessageVisitor v) {
  final dec = sofab.Decoder(v);
  var st = sofab.DecodeStatus.complete;
  for (final b in bytes) {
    st = dec.feed([b]);
  }
  return st;
}

/// Records the headers the codec reports and declines every destination — the
/// shape of a generated scope reaching a field it does not declare.
class _Recorder extends sofab.MessageVisitor {
  final List<List<Object>> begins = [];
  final List<List<Object>> headers = [];
  final List<int> dests = [];
  final List<int> done = [];

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) =>
      begins.add([id, kind, count]);

  @override
  void onFixlenHeader(int id, int subtype, int length) =>
      headers.add([id, subtype, length]);

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) {
    dests.add(id);
    return null;
  }

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    dests.add(id);
    return null;
  }

  @override
  void onArrayDone(int id, sofab.ArrayKind kind, TypedData dest, int count) =>
      done.add(id);
}

/// Stands in for generated code carrying the three configured caps: it applies
/// each at the header hook, on a schema that bounds nothing, and refuses with
/// [sofab.MessageVisitor.limitExceeded] — the category §6.3 reserves for a
/// policy rejection.
class _Capped extends sofab.MessageVisitor {
  _Capped({
    this.maxArrayCount = sofab.arrayMax,
    this.maxStringLen = sofab.fixlenMax,
    this.maxBlobLen = sofab.fixlenMax,
    this.skipIds = const <int>{},
  });

  final int maxArrayCount;
  final int maxStringLen;
  final int maxBlobLen;
  final Set<int> skipIds;

  final List<int> dests = [];
  final List<String> strings = [];

  @override
  bool shouldRead(int id, int type) => !skipIds.contains(id);

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) {
    if (count > maxArrayCount) limitExceeded();
  }

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (subtype == sofab.FixlenType.string && length > maxStringLen) {
      limitExceeded();
    }
    if (subtype == sofab.FixlenType.blob && length > maxBlobLen) {
      limitExceeded();
    }
  }

  @override
  void onString(int id, String value) => strings.add(value);

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) {
    dests.add(id);
    return super.onBytesDest(id, subtype, total);
  }

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    dests.add(id);
    return super.onArrayDest(id, kind, count);
  }
}
