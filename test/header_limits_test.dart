import 'dart:io';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The shared `header_limits` block (CORELIB_PLAN §6.2.1, §6.3; MESSAGE_SPEC
/// §5.2, §7.1).
///
/// It carries the one class no other block could: **bytes that declare a length
/// or a count and then end**, with not one payload byte behind them.
///
/// ```text
/// 02 a2 06   then EOF
/// ^^ id 0, wire type 2 (fixlen)
///    ^^^^^ length word (100 << 3) | 2  ->  a 100-byte STRING is declared
///            ... and the message ends.
/// ```
///
/// A conformant decoder answers **at that word**, before the payload is asked
/// for, so the answer is the ceiling's and it is **terminal**. `INCOMPLETE`
/// would be the outcome MESSAGE_SPEC §5.2.3's reason exists to prevent: §5.2.1
/// defines it as the verdict more bytes *can* change, and after a ceiling has
/// fired nothing can.
///
/// **Which ceiling speaks is the subject.** The two give opposite answers on the
/// same word, and a case carries one or the other — never both, because §6.2.1
/// forbids applying a receiver cap to a field the schema already bounds:
///
/// | the case states | the ceiling | a breach is |
/// |---|---|---|
/// | `"schema": {"maxlen": N}` | the schema bound | `invalid` (§7.1) |
/// | `"limits": {"max_dyn_…": N}` | the receiver cap | `limit_exceeded` (§6.2.1) |
///
/// `header_string_schema_bounded` and `header_string_over_cap` carry the
/// identical bytes and differ only in which ceiling the case configures. That
/// pair is what keeps the two categories apart.
///
/// Neither ceiling is the codec's here, exactly as in `schema_bound_limit_test`:
/// both are stated by [_Ceiling] below, standing in for what the generator
/// emits, in the header hooks the decoder already calls before it asks for
/// storage — [sofab.MessageVisitor.onFixlenHeader] for a `string`/`blob` length,
/// [sofab.MessageVisitor.onArrayBegin] for an array count.
void main() {
  final root =
      decodeVectorJson(File('assets/test_vectors.json').readAsStringSync())
          as Map;
  final cases = (root['header_limits'] as List?)?.cast<Map<String, dynamic>>();

  test('the header_limits block is present', () {
    expect(
      cases,
      isNotNull,
      reason: 'assets/test_vectors.json predates the header_limits block',
    );
    expect(cases, isNotEmpty);
  });

  if (cases == null) return;

  for (final c in cases) {
    final name = c['name'] as String;
    final requires = ((c['requires'] as List?) ?? const []).cast<String>();
    final fieldId = jInt(c['field_id']);
    final declared = jInt(c['declared']);
    final limits = (c['limits'] as Map?)?.cast<String, dynamic>();
    final schema = (c['schema'] as Map?)?.cast<String, dynamic>();
    final expected = (c['expect'] as Map).cast<String, dynamic>();
    final want = _outcome(expected['outcome'] as String);
    final terminal = expected['terminal'] == true;
    final bytes = hexToBytes(c['serialized'] as String);
    final chunks = ((c['chunks'] as List?) ?? const [])
        .cast<String>()
        .map(hexToBytes)
        .toList();

    // An unsatisfied `requires` tag means SKIP in this block — for every tag,
    // not just the profile ones, and unlike a *vector*, where a missing wire
    // construct turns the case into a negative one. These cases already assert
    // a rejection with a specific category, so a build that cannot represent
    // the construct would reject it for an unrelated reason and appear to pass
    // while testing nothing.
    final unmet = requires.where((r) => !_supportedCapabilities.contains(r));

    /// The ceiling this case configures, fresh per decode surface. A port
    /// restores its own configuration after the block; here every ceiling is a
    /// constructor argument, so there is nothing global to restore.
    _Ceiling ceiling() => _Ceiling(
      fieldId,
      schemaMaxlen: schema == null ? -1 : jInt(schema['maxlen']),
      maxStringLen: _cap(limits, 'max_dyn_string_len', sofab.fixlenMax),
      maxBlobLen: _cap(limits, 'max_dyn_blob_len', sofab.fixlenMax),
      maxArrayCount: _cap(limits, 'max_dyn_array_count', sofab.arrayMax),
    );

    test(
      '$name (${c['group']})',
      () {
        expect(
          limits == null || schema == null,
          isTrue,
          reason: 'a case states one ceiling or the other, never both (§6.2.1)',
        );
        expect(
          limits != null || schema != null,
          isTrue,
          reason: 'a case states a ceiling to configure',
        );

        // 1. The one-shot surface: the whole byte string in one call.
        final one = ceiling();
        expect(
          sofab.Decoder.decode(bytes, one),
          want,
          reason: 'one-shot outcome',
        );
        expect(
          one.headerValue,
          declared,
          reason: 'the header word carries the length/count the case declares',
        );

        // 2. The streaming surface, in the case's own chunking where it states
        //    one — `header_string_over_cap_split` divides the length varint
        //    itself, so the ceiling has to fire on a word no single feed
        //    delivered whole (§7.2 item 4).
        final streamed = ceiling();
        final dec = sofab.Decoder(streamed);
        var st = dec.feed(const <int>[]);
        for (final chunk in chunks.isEmpty ? [bytes] : chunks) {
          st = dec.feed(chunk);
        }
        expect(
          st,
          want,
          reason: chunks.isEmpty
              ? 'streaming outcome (one feed)'
              : 'streaming outcome (${chunks.length} chunks)',
        );
        expect(streamed.headerValue, declared);

        // 3. ... and again one byte per feed, the finest split there is.
        final perByte = ceiling();
        final dec2 = sofab.Decoder(perByte);
        var st2 = dec2.feed(const <int>[]);
        for (final b in bytes) {
          st2 = dec2.feed(Uint8List.fromList([b]));
        }
        expect(st2, want, reason: 'streaming outcome (one byte per feed)');

        if (terminal) {
          // §6.3: the rejection is terminal. A further feed **re-raises** rather
          // than consuming — and the bytes fed are the very payload the header
          // promised, so a decoder that resumed would be caught taking them.
          final payload = Uint8List(16);
          expect(dec.feed(payload), want, reason: 'terminal: re-raises');
          expect(dec.feed(payload), want, reason: 'terminal: and stays');
          expect(dec2.feed(payload), want);
          expect(dec2.feed(const <int>[]), want);
        } else {
          // The in-cap control. It is not filler: the same shape at a length the
          // ceiling admits must still answer `incomplete`, or a port that
          // rejects every short read would pass all six rejection cases while
          // being badly broken.
          expect(want, sofab.DecodeStatus.incomplete);
          // `incomplete` is precisely the state more bytes lift (§5.2.1), which
          // is what makes it the opposite of the terminal branch above. One zero
          // byte per declared byte (a `string`/`blob` payload) or per declared
          // element (a one-byte varint each) completes the message.
          expect(
            dec2.feed(Uint8List(declared)),
            sofab.DecodeStatus.complete,
            reason: 'the control is liftable — that is what INCOMPLETE means',
          );
        }
      },
      skip: unmet.isEmpty
          ? null
          : 'this port declares no ${unmet.join(", ")} capability',
    );
  }

  // ------------------------------------------------------------------
  // The block's own structure, asserted rather than assumed.
  // ------------------------------------------------------------------

  test('every rejection is paired with an in-cap control', () {
    // "Treat a missing control as a bug in the block, not an omission." The
    // pairing is by the ceiling configuration: the control is the same ceiling
    // at a length it admits.
    String ceilingKey(Map<String, dynamic> c) {
      final m = (c['limits'] ?? c['schema']) as Map;
      final keys = m.keys.cast<String>().toList()..sort();
      return keys.map((k) => '$k=${m[k]}').join(',');
    }

    final controls = cases
        .where((c) => (c['expect'] as Map)['outcome'] == 'incomplete')
        .map(ceilingKey)
        .toSet();
    final rejections = cases.where(
      (c) => (c['expect'] as Map)['outcome'] != 'incomplete',
    );
    expect(rejections, isNotEmpty);
    for (final c in rejections) {
      expect(
        controls,
        contains(ceilingKey(c)),
        reason: '${c['name']} has no in-cap control',
      );
    }
  });

  group('negative control: the same bytes with the ceilings lifted', () {
    // What demonstrates the verdicts above come from the ceiling and not from
    // something incidental. With every ceiling wound out to the format's own
    // (there is no "unconfigured" state — §6.2.1 admits none), each rejection
    // falls back to the truncation it also is.
    //
    // All six fall back here, where the block's C++ reference run reported five
    // of six: the sixth there is `header_string_amplification`, whose 1 GiB
    // claim meets a lower format ceiling. This port's [sofab.fixlenMax] is
    // 2^31-1, above that claim, so with the cap lifted nothing else fires and
    // the bytes are simply a truncated header.
    for (final c in cases.where(
      (c) => (c['expect'] as Map)['outcome'] != 'incomplete',
    )) {
      final name = c['name'] as String;
      final fieldId = jInt(c['field_id']);
      final bytes = hexToBytes(c['serialized'] as String);

      test('$name falls back to incomplete', () {
        expect(
          sofab.Decoder.decode(bytes, _Ceiling(fieldId)),
          sofab.DecodeStatus.incomplete,
          reason: 'one-shot, no ceiling',
        );
        final dec = sofab.Decoder(_Ceiling(fieldId));
        var st = dec.feed(const <int>[]);
        for (final b in bytes) {
          st = dec.feed(Uint8List.fromList([b]));
        }
        expect(
          st,
          sofab.DecodeStatus.incomplete,
          reason: 'streaming, no ceiling',
        );
      });
    }
  });
}

/// The capabilities this port implements, in the vocabulary the block's
/// `requires` sets use. The three wire-construct tags are the same ones
/// `vectors_test.dart` declares; `receiver_caps` is the **profile** one, and
/// this port declares it because its generated layer carries §6.2.1 caps
/// distinct from schema bounds — the pair of statements
/// `schema_bound_limit_test.dart` pins, and [_Ceiling] below restates for these
/// bytes.
const Set<String> _supportedCapabilities = {
  'fixlen',
  'array',
  'int64',
  'receiver_caps',
};

int _cap(Map<String, dynamic>? limits, String key, int fallback) =>
    limits == null || limits[key] == null ? fallback : jInt(limits[key]);

sofab.DecodeStatus _outcome(String name) => switch (name) {
  'complete' => sofab.DecodeStatus.complete,
  'incomplete' => sofab.DecodeStatus.incomplete,
  'invalid' => sofab.DecodeStatus.invalid,
  'limit_exceeded' => sofab.DecodeStatus.limitExceeded,
  _ => fail('unknown outcome $name'),
};

/// Stands in for generated code carrying **one** ceiling for **one** field.
///
/// Either a schema `maxlen` (breach → [sofab.MessageVisitor.invalidate],
/// MESSAGE_SPEC §7.1) or a §6.2.1 receiver cap (breach →
/// [sofab.MessageVisitor.limitExceeded]) — never both on the same field, which
/// is what the two constructor shapes make structural rather than a rule someone
/// has to remember. Both statements are made in the header hook, which fires at
/// the length/count word, before storage is asked for and before truncation is
/// known.
class _Ceiling extends sofab.MessageVisitor {
  _Ceiling(
    this.fieldId, {
    this.schemaMaxlen = -1,
    this.maxStringLen = sofab.fixlenMax,
    this.maxBlobLen = sofab.fixlenMax,
    this.maxArrayCount = sofab.arrayMax,
  });

  final int fieldId;

  /// The schema bound on [fieldId], or -1 when the schema leaves it unbounded —
  /// which is the only state in which a receiver cap may apply at all.
  final int schemaMaxlen;
  final int maxStringLen;
  final int maxBlobLen;
  final int maxArrayCount;

  /// The length or count the header actually carried, recorded before any
  /// ceiling is applied, so a misparsed varint cannot hide behind the right
  /// verdict.
  int? headerValue;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (id != fieldId) return;
    headerValue = length;
    if (schemaMaxlen >= 0) {
      if (length > schemaMaxlen) invalidate();
      return;
    }
    if (subtype == sofab.FixlenType.string) {
      if (length > maxStringLen) limitExceeded();
    } else if (subtype == sofab.FixlenType.blob) {
      if (length > maxBlobLen) limitExceeded();
    }
  }

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) {
    if (id != fieldId) return;
    headerValue = count;
    if (schemaMaxlen >= 0) {
      if (count > schemaMaxlen) invalidate();
      return;
    }
    if (count > maxArrayCount) limitExceeded();
  }

  /// Storage for anything this block could actually deliver, and a decline above
  /// that. Generated code would hand over the caller's own list here; the
  /// difference matters only for the amplification case, whose header claims a
  /// gigabyte that no message in the block carries — and this hook fires *after*
  /// the ceiling above, so declining changes no verdict, only what an
  /// implementation whose ceiling is momentarily broken (the failing-first
  /// proof) is asked to allocate.
  static const int _willingToHold = 1 << 20;

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) =>
      total > _willingToHold ? null : super.onBytesDest(id, subtype, total);

  @override
  TypedData? onArrayDest(int id, sofab.ArrayKind kind, int count) =>
      count > _willingToHold ? null : super.onArrayDest(id, kind, count);
}
