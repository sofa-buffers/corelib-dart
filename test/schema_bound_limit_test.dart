import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// Receiver-side limits vs. SCHEMA bounds (CORELIB_PLAN §6.2.1, §6.3).
///
/// A `DecoderLimits` cap is deployment configuration protecting the receiver
/// from a field the schema leaves *unbounded*. It "MUST NOT be applied to a
/// field the schema already bounds. There the schema bound governs and its
/// violation is INVALID" — and `LimitExceeded` is "never raised for a field the
/// schema bounds". Only the schema knows which fields those are, so the visitor
/// declares them through [sofab.MessageVisitor.onFixlenLenBound] /
/// [sofab.MessageVisitor.onArrayCountBound] (issue #40).
///
/// Every case here pairs a schema-bounded field with an unbounded control one
/// byte away, so what is pinned is the DISTINCTION, not a blanket outcome.
void main() {
  // The schema this file's visitor stands for:
  //   id 1: blob   maxlen 64
  //   id 2: string maxlen 8
  //   id 3: u64[]  count  8
  //   id 4: fp32[] count  8
  //   id 9: every type, no bound declared at all
  //
  // Runs the same bytes through both decode surfaces — the one-shot contiguous
  // walker and the streaming state machine fed one byte at a time — and asserts
  // they agree, since the two reach a header verdict by different routes.
  sofab.DecodeStatus bothPaths(Uint8List bytes, sofab.DecoderLimits limits) {
    final cSt = sofab.Decoder.decode(bytes, _Schema(), limits: limits);

    final dec = sofab.Decoder(_Schema(), limits: limits);
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
        // blob of 100 bytes at a field the schema bounds at 64, decoded with a
        // 4-byte cap: the cap must not fire, and the schema breach is INVALID.
        final bytes = enc((e) => e.writeBlob(1, Uint8List(100)));
        expect(
          bothPaths(bytes, const sofab.DecoderLimits(maxBlobLen: 4)),
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
        bothPaths(bytes, const sofab.DecoderLimits(maxBlobLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('string over its schema maxlen → invalid', () {
      final bytes = enc((e) => e.writeString(2, 'x' * 16));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits(maxStringLen: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test('string within its schema maxlen but over the cap → complete', () {
      final bytes = enc((e) => e.writeString(2, 'xxxxxx'));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits(maxStringLen: 4)),
        sofab.DecodeStatus.complete,
      );
    });

    test('control: an UNBOUNDED field keeps the cap → limitExceeded', () {
      final blob = enc((e) => e.writeBlob(9, Uint8List(32)));
      expect(
        bothPaths(blob, const sofab.DecoderLimits(maxBlobLen: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      final str = enc((e) => e.writeString(9, 'xxxxxx'));
      expect(
        bothPaths(str, const sofab.DecoderLimits(maxStringLen: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('control: no cap configured at all → complete', () {
      final bytes = enc((e) => e.writeBlob(9, Uint8List(32)));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits()),
        sofab.DecodeStatus.complete,
      );
    });
  });

  group('array count: the schema count governs, the cap stays off', () {
    test('integer array over its schema count → invalid', () {
      final bytes = enc((e) => e.writeUnsignedArray(3, List.filled(20, 1)));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test(
      'integer array within its schema count but over the cap → complete',
      () {
        final bytes = enc((e) => e.writeUnsignedArray(3, List.filled(6, 1)));
        expect(
          bothPaths(bytes, const sofab.DecoderLimits(maxArrayCount: 4)),
          sofab.DecodeStatus.complete,
        );
      },
    );

    test('fixlen array over its schema count → invalid', () {
      final bytes = enc((e) => e.writeFp32Array(4, List.filled(20, 1.5)));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.invalid,
      );
    });

    test(
      'fixlen array within its schema count but over the cap → complete',
      () {
        final bytes = enc((e) => e.writeFp32Array(4, List.filled(6, 1.5)));
        expect(
          bothPaths(bytes, const sofab.DecoderLimits(maxArrayCount: 4)),
          sofab.DecodeStatus.complete,
        );
      },
    );

    test('an element kind the schema does not declare keeps the cap', () {
      // id 4 is declared fp32[]; an fp64 array there is a MESSAGE_SPEC §7.3
      // skip and was never this field's value, so this field's `count` bound
      // must not be measured against it — and the receiver cap, which protects
      // exactly the fields no schema bound covers, still applies.
      final bytes = enc((e) => e.writeFp64Array(4, List.filled(20, 1.5)));
      expect(
        bothPaths(bytes, const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('control: an UNBOUNDED array keeps the cap → limitExceeded', () {
      final ints = enc((e) => e.writeUnsignedArray(9, List.filled(20, 1)));
      expect(
        bothPaths(ints, const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
      final f32 = enc((e) => e.writeFp32Array(9, List.filled(20, 1.5)));
      expect(
        bothPaths(f32, const sofab.DecoderLimits(maxArrayCount: 4)),
        sofab.DecodeStatus.limitExceeded,
      );
    });
  });

  group('the header hook fires before the cap can reject', () {
    // Part of the same defect: the cap short-circuited the hooks, so a
    // schema-bound consumer that enforces its bound in onFixlenHeader /
    // onArrayBegin never even learned of the breach. The hook fires at the
    // header — before any allocation — whatever the cap then decides.
    test('onFixlenHeader fires on a capped, unbounded field', () {
      final bytes = enc((e) => e.writeBlob(9, Uint8List(32)));
      final v = _Schema();
      expect(
        sofab.Decoder.decode(
          bytes,
          v,
          limits: const sofab.DecoderLimits(maxBlobLen: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(v.fixlenHeaders, [
        [9, sofab.FixlenType.blob, 32],
      ]);

      final s = _Schema();
      final dec = sofab.Decoder(
        s,
        limits: const sofab.DecoderLimits(maxBlobLen: 4),
      );
      for (final b in bytes) {
        dec.feed([b]);
      }
      expect(s.fixlenHeaders, [
        [9, sofab.FixlenType.blob, 32],
      ]);
    });

    test('onArrayBegin fires on a capped, unbounded array', () {
      final bytes = enc((e) => e.writeUnsignedArray(9, List.filled(20, 1)));
      final v = _Schema();
      expect(
        sofab.Decoder.decode(
          bytes,
          v,
          limits: const sofab.DecoderLimits(maxArrayCount: 4),
        ),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(v.arrayBegins, [
        [9, sofab.ArrayKind.unsigned, 20],
      ]);

      final s = _Schema();
      final dec = sofab.Decoder(
        s,
        limits: const sofab.DecoderLimits(maxArrayCount: 4),
      );
      for (final b in bytes) {
        dec.feed([b]);
      }
      expect(s.arrayBegins, [
        [9, sofab.ArrayKind.unsigned, 20],
      ]);
    });
  });

  group('a skipped field is nobody\'s schema field', () {
    test('a declined id keeps the cap (nothing is materialized)', () {
      // shouldRead false → the payload is a length jump, never materialized, so
      // no allocation is capped and no schema bound is stated: the decode just
      // walks past it. Pins that the exemption did not turn into "the cap is
      // gone".
      final bytes = enc((e) => e.writeBlob(7, Uint8List(100)));
      expect(
        sofab.Decoder.decode(
          bytes,
          _Schema(),
          limits: const sofab.DecoderLimits(maxBlobLen: 4),
        ),
        sofab.DecodeStatus.complete,
      );
    });
  });
}

/// Stands in for a generated, schema-bound consumer: it answers the two bound
/// hooks from its declaration table and records the header hooks.
class _Schema extends sofab.MessageVisitor {
  final List<List<Object>> fixlenHeaders = [];
  final List<List<Object>> arrayBegins = [];

  @override
  bool shouldRead(int id, int type) => id != 7; // id 7 is not in the schema

  @override
  int? onFixlenLenBound(int id, int subtype) {
    if (id == 1 && subtype == sofab.FixlenType.blob) return 64;
    if (id == 2 && subtype == sofab.FixlenType.string) return 8;
    return null; // id 9 (and every other id) declares no maxlen
  }

  @override
  int? onArrayCountBound(int id, sofab.ArrayKind kind) {
    if (id == 3 && kind == sofab.ArrayKind.unsigned) return 8;
    if (id == 4 && kind == sofab.ArrayKind.fp32) return 8;
    return null; // id 9, and an fp64 array at id 4 (a §7.3 skip)
  }

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    fixlenHeaders.add([id, subtype, length]);
  }

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) {
    arrayBegins.add([id, kind, count]);
  }
}
