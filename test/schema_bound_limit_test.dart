import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// Receiver-side caps vs. SCHEMA bounds (CORELIB_PLAN §6.2.1, §6.3).
///
/// A `max_dyn_*` cap is deployment configuration protecting the receiver from a
/// field the schema leaves *unbounded*. It "MUST NOT be applied to a field the
/// schema already bounds. There the schema bound governs and its violation is
/// INVALID" — and `LimitExceeded` is "never raised for a field the schema
/// bounds".
///
/// **Neither number is the codec's** (§6.2.1: *"The numbers and the allocation
/// are not the codec's … the visitor decides. The codec never invents a limit of
/// its own"*). Both are the consumer's, and both are stated in the same place —
/// the header hook the decoder already calls before it asks for storage:
/// [sofab.MessageVisitor.onFixlenHeader] for a `string`/`blob` length,
/// [sofab.MessageVisitor.onArrayBegin] for an array count. The cap is the
/// **else** of the schema bound, which is what makes "never both" structural
/// rather than a rule someone has to remember.
///
/// [_Schema] below stands in for what the generator emits. Every case pairs a
/// schema-bounded field with an unbounded control one byte away, so what is
/// pinned is the DISTINCTION, not a blanket outcome.
void main() {
  // The schema this file's visitor stands for:
  //   id 1: blob   maxlen 64
  //   id 2: string maxlen 8
  //   id 3: u64[]  count  8
  //   id 4: fp32[] count  8
  //   id 9: every type, no bound declared at all
  //   id 7: not in the schema; declined at header time
  //   id 8: not in the schema; not declined either
  //
  // Runs the same bytes through both decode surfaces — the one-shot contiguous
  // walker and the streaming state machine fed one byte at a time — and asserts
  // they agree, since the two reach a header verdict by different routes.
  sofab.DecodeStatus bothPaths(Uint8List bytes, _Schema Function() make) {
    final cSt = sofab.Decoder.decode(bytes, make());

    final dec = sofab.Decoder(make());
    var sSt = sofab.DecodeStatus.complete;
    for (final b in bytes) {
      sSt = dec.feed([b]);
    }
    if (bytes.isEmpty) sSt = dec.feed(const []);

    expect(sSt, cSt, reason: 'streaming and contiguous paths must agree');
    return cSt;
  }

  Uint8List enc(void Function(sofab.Encoder) body) =>
      sofab.Encoder.encodeToBytes(body);

  group('fixlen: the schema maxlen governs, the cap stays off', () {
    test(
      'over the schema maxlen, under nothing → invalid, not limitExceeded',
      () {
        // blob of 100 bytes at a field the schema bounds at 64, with a 4-byte
        // cap configured: the cap must not fire, and the schema breach is
        // INVALID.
        final bytes = enc((e) => e.writeBlob(1, Uint8List(100)));
        expect(
          bothPaths(bytes, () => _Schema(maxBlobLen: 4)),
          sofab.DecodeStatus.invalid,
        );
      },
    );

    test('within the schema maxlen but over the cap → complete', () {
      // The whole point of the exemption: 32 bytes is a perfectly good value of
      // a `blob<maxlen 64>` field, and a deployment cap sized for UNBOUNDED
      // fields must not reject it.
      final bytes = enc((e) => e.writeBlob(1, Uint8List(32)));
      expect(
        bothPaths(bytes, () => _Schema(maxBlobLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('string over its schema maxlen → invalid', () {
      final bytes = enc((e) => e.writeString(2, 'x' * 16));
      expect(
        bothPaths(bytes, () => _Schema(maxStringLen: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test('string within its schema maxlen but over the cap → complete', () {
      final bytes = enc((e) => e.writeString(2, 'xxxxxx'));
      expect(
        bothPaths(bytes, () => _Schema(maxStringLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('control: an UNBOUNDED field keeps the cap → limitExceeded', () {
      final blob = enc((e) => e.writeBlob(9, Uint8List(32)));
      expect(
        bothPaths(blob, () => _Schema(maxBlobLen: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      final str = enc((e) => e.writeString(9, 'xxxxxx'));
      expect(
        bothPaths(str, () => _Schema(maxStringLen: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('control: a cap wound out to the format ceiling → complete', () {
      // There is no "unconfigured" state to test instead: §6.2.1 admits none,
      // and [_Schema] has no way to express one. The loosest a receiver can be
      // is the format's own ceiling.
      final bytes = enc((e) => e.writeBlob(9, Uint8List(32)));
      expect(bothPaths(bytes, _Schema.new), sofab.DecodeStatus.complete);
    });
  });

  group('array count: the schema count governs, the cap stays off', () {
    test('integer array over its schema count → invalid', () {
      final bytes = enc((e) => e.writeUnsignedArray(3, List.filled(20, 1)));
      expect(
        bothPaths(bytes, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test(
      'integer array within its schema count but over the cap → complete',
      () {
        final bytes = enc((e) => e.writeUnsignedArray(3, List.filled(6, 1)));
        expect(
          bothPaths(bytes, () => _Schema(maxArrayCount: 4)),
          sofab.DecodeStatus.complete,
        );
      },
    );

    test('fixlen array over its schema count → invalid', () {
      final bytes = enc((e) => e.writeFp32Array(4, List.filled(20, 1.5)));
      expect(
        bothPaths(bytes, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test(
      'fixlen array within its schema count but over the cap → complete',
      () {
        final bytes = enc((e) => e.writeFp32Array(4, List.filled(6, 1.5)));
        expect(
          bothPaths(bytes, () => _Schema(maxArrayCount: 4)),
          sofab.DecodeStatus.complete,
        );
      },
    );

    test('control: an UNBOUNDED array keeps the cap → limitExceeded', () {
      final ints = enc((e) => e.writeUnsignedArray(9, List.filled(20, 1)));
      expect(
        bothPaths(ints, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      final f32 = enc((e) => e.writeFp32Array(9, List.filled(20, 1.5)));
      expect(
        bothPaths(f32, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
    });
  });

  // §6.2.1, the sentence the retired codec-side caps could not honour: *"A
  // skipped field is never capped. A limit bounds an allocation, and a field the
  // handler skips allocates nothing … a decode that steps over an over-cap field
  // it was never going to read stays COMPLETE."* A cap held by the decoder fired
  // on every field alike, because it could not tell which ones the consumer had
  // arms for. A cap stated inside an arm cannot make that mistake: the arm is
  // the answer to "is this field mine".
  group('a skipped field is never capped', () {
    test('an id the consumer declines is never capped', () {
      // shouldRead false → the payload is a length jump, never materialized.
      final bytes = enc((e) => e.writeBlob(7, Uint8List(100)));
      expect(
        bothPaths(bytes, () => _Schema(maxBlobLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('an id the schema does not declare at all is never capped', () {
      // The case a decoder-level cap got wrong (generator#410): id 8 is read —
      // the consumer declines nothing — but no arm claims it, so no bound of
      // this schema's covers it and the decode walks past.
      final blob = enc((e) => e.writeBlob(8, Uint8List(100)));
      expect(
        bothPaths(blob, () => _Schema(maxBlobLen: 4)),
        sofab.DecodeStatus.complete,
      );
      final arr = enc((e) => e.writeUnsignedArray(8, List.filled(20, 1)));
      expect(
        bothPaths(arr, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('an element kind the schema does not declare is never capped', () {
      // id 4 is declared fp32[]; an fp64 array there is a MESSAGE_SPEC §7.3
      // skip and was never this field's value, so neither this field's `count`
      // nor the receiver cap is measured against it. The old decoder-level cap
      // rejected this as limitExceeded — the same defect one level down.
      final bytes = enc((e) => e.writeFp64Array(4, List.filled(20, 1.5)));
      expect(
        bothPaths(bytes, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.complete,
      );
      // A subtype mismatch on a fixlen scalar decides the same way.
      final str = enc((e) => e.writeString(1, 'x' * 100));
      expect(
        bothPaths(str, () => _Schema(maxStringLen: 4, maxBlobLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });
  });

  group('the header hook is where both statements are made', () {
    // The decoder reports and never judges (§6.2.1), so the hook firing IS the
    // enforcement point: it carries the count/length, it fires before the
    // destination is asked for, and it fires for every field being read —
    // whatever the consumer then decides.
    test('onFixlenHeader carries the length that is then refused', () {
      final bytes = enc((e) => e.writeBlob(9, Uint8List(32)));
      final v = _Schema(maxBlobLen: 4);
      expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.limitExceeded);
      expect(v.fixlenHeaders, [
        [9, sofab.FixlenType.blob, 32],
      ]);
      expect(v.bytesDests, isEmpty, reason: 'refused before the allocation');

      final s = _Schema(maxBlobLen: 4);
      final dec = sofab.Decoder(s);
      for (final b in bytes) {
        dec.feed([b]);
      }
      expect(s.fixlenHeaders, [
        [9, sofab.FixlenType.blob, 32],
      ]);
      expect(s.bytesDests, isEmpty);
    });

    test('onArrayBegin carries the count that is then refused', () {
      final bytes = enc((e) => e.writeUnsignedArray(9, List.filled(20, 1)));
      final v = _Schema(maxArrayCount: 4);
      expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.limitExceeded);
      expect(v.arrayBegins, [
        [9, sofab.ArrayKind.unsigned, 20],
      ]);
      expect(v.arrayDests, isEmpty, reason: 'refused before the allocation');

      final s = _Schema(maxArrayCount: 4);
      final dec = sofab.Decoder(s);
      for (final b in bytes) {
        dec.feed([b]);
      }
      expect(s.arrayBegins, [
        [9, sofab.ArrayKind.unsigned, 20],
      ]);
      expect(s.arrayDests, isEmpty);
    });

    test('the two categories stay apart, and both stay terminal', () {
      // §6.3: an implementation MUST keep them distinguishable to the caller.
      final over = enc((e) => e.writeUnsignedArray(9, List.filled(20, 1)));
      expect(
        bothPaths(over, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      final bad = enc((e) => e.writeUnsignedArray(3, List.filled(20, 1)));
      expect(
        bothPaths(bad, () => _Schema(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });
  });
}

/// Stands in for a generated, schema-bound consumer.
///
/// The three caps are constructor arguments because that is what they are in
/// generated code: `max_dyn_array_count`, `max_dyn_string_len` and
/// `max_dyn_blob_len` are sofabgen config keys, baked in as constants per
/// package. There is no unset state (§6.2.1) — the loosest value is the format
/// ceiling, and the library offers no default to fall back on.
class _Schema extends sofab.MessageVisitor {
  _Schema({
    this.maxArrayCount = sofab.arrayMax,
    this.maxStringLen = sofab.fixlenMax,
    this.maxBlobLen = sofab.fixlenMax,
  });

  final int maxArrayCount;
  final int maxStringLen;
  final int maxBlobLen;

  final List<List<Object>> fixlenHeaders = [];
  final List<List<Object>> arrayBegins = [];
  final List<int> bytesDests = [];
  final List<int> arrayDests = [];

  @override
  bool shouldRead(int id, int type) => id != 7; // id 7 is declined outright

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    fixlenHeaders.add([id, subtype, length]);
    // Every arm is gated on the DECLARED subtype: a contradicting header is a
    // §7.3 skip and must not be measured against this field's bound — nor
    // against the cap, which covers a field this schema declares and leaves
    // unbounded, not one it does not declare at all.
    if (subtype == sofab.FixlenType.blob) {
      if (id == 1) {
        if (length > 64) invalidate(); // schema maxlen
        return;
      }
      if (id == 9) {
        if (length > maxBlobLen) limitExceeded(); // no schema maxlen: the cap
        return;
      }
      return;
    }
    if (subtype == sofab.FixlenType.string) {
      if (id == 2) {
        if (length > 8) invalidate();
        return;
      }
      if (id == 9) {
        if (length > maxStringLen) limitExceeded();
        return;
      }
    }
  }

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) {
    arrayBegins.add([id, kind, count]);
    if (kind == sofab.ArrayKind.unsigned) {
      if (id == 3) {
        if (count > 8) invalidate(); // schema count
        return;
      }
      if (id == 9) {
        if (count > maxArrayCount) limitExceeded();
        return;
      }
      return;
    }
    if (kind == sofab.ArrayKind.fp32) {
      if (id == 4) {
        if (count > 8) invalidate();
        return;
      }
      if (id == 9) {
        if (count > maxArrayCount) limitExceeded();
        return;
      }
    }
  }

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) {
    bytesDests.add(id);
    return super.onBytesDest(id, subtype, total);
  }

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) {
    arrayDests.add(id);
    return super.onArrayDest(id, kind, count);
  }
}
