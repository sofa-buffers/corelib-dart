import 'dart:io';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The shared `boolean_tolerant` block (CORELIB_PLAN §4.4).
///
/// > **Canonical on encode, tolerant on decode.** An encoder **MUST** write
/// > `true` as `1`. A decoder **MUST** read **every value other than `0`** as
/// > `true`: such a value is **not** `INVALID` (§5.2), it is normalized away,
/// > and a re-encode emits `1`.
///
/// A boolean has no wire type of its own — it rides the unsigned varint (§4.4)
/// and, as an array, the unsigned-varint-array wire type. So every case here is
/// ordinary, well-formed wire; what is under test is purely how a boolean is
/// *interpreted*, stored and written back out. That is also why the positive
/// `vectors` block cannot reach this half of §4.4: those bytes come from a
/// conforming encoder, and a conforming encoder never emits `2` at a boolean
/// position. Bytes like these only ever arrive from *someone else's* encoder,
/// hence a separate, hand-authored block.
///
/// The three defects it is built to catch land in three different assertions:
///
/// | defect | caught by |
/// |---|---|
/// | answers `INVALID` for `256` (a boolean treated as a 1-byte type) | the outcome check |
/// | truncates `256` to the destination width, so it decodes to **false** | the value check — the outcome is `complete` and looks perfect |
/// | stores the raw `2` without normalizing | the **re-encode** check — the outcome, and any truthiness test, still pass |
///
/// Both defects the block was written for were real: `corelib-c-cpp#172` and
/// `sofa-buffers/generator#581`.
///
/// **This port's boolean surface.** Dart has no separate boolean wire type and
/// this corelib exposes none: a boolean is *written* by
/// [sofab.Encoder.writeBool] (which is where "canonical on encode" lives — it
/// emits `1`, never the raw value) and *read* by
/// [sofab.MessageVisitor.onUnsigned], where the generated layer performs the
/// explicit `!= 0` test that §4.4 demands. [_BoolField] below stands in for
/// that generated layer, so the zero test happens exactly where a real consumer
/// puts it and the destination is a Dart `bool` — a representation that cannot
/// hold `2` at all (the byte-level read-back of §8 in the runner spec is for
/// languages whose `bool` object could).
///
/// Because that zero test is the *consumer's* here, the value check alone would
/// not see a decoder that truncated `65535` to `255` — still non-zero, still
/// `true`. So each case additionally pins the **raw** value the codec delivered
/// against the varints read straight out of `serialized_hex` ([_wireValues]):
/// that is what holds the codec to the full-width read §4.4 requires.
void main() {
  final root =
      decodeVectorJson(File('assets/test_vectors.json').readAsStringSync())
          as Map;
  final cases = (root['boolean_tolerant'] as List?)
      ?.cast<Map<String, dynamic>>();

  test('the boolean_tolerant block is present', () {
    expect(
      cases,
      isNotNull,
      reason: 'assets/test_vectors.json predates the boolean_tolerant block',
    );
    expect(cases, isNotEmpty);
    // A floor, not an equality: the block may grow upstream. What this catches
    // is a stale copy of the asset or a loader that truncated — either of which
    // would otherwise iterate nothing and leave the suite green.
    expect(cases!.length, greaterThanOrEqualTo(_minCases));
  });

  if (cases == null) return;

  // found / decoded / rejected / checks, reported by the inventory test below.
  var decoded = 0;
  var rejected = 0;
  var checks = 0;

  for (final c in cases) {
    final name = c['name'] as String;
    final requires = ((c['requires'] as List?) ?? const []).cast<String>();
    final fieldId = jInt(c['id']);
    final bytes = hexToBytes(c['serialized_hex'] as String);
    final expected = (c['expect'] as Map).cast<String, dynamic>();
    final want = _outcome(expected['outcome'] as String);
    final values = (expected['values'] as List).cast<bool>();
    final reencoded = expected['reencoded_hex'] as String;

    // §4.4 lifts the width bound the *type* carries, not the one a particular
    // *build* has. An unsatisfied tag therefore means the message must be
    // REJECTED, not skipped: under a narrowed accumulator a boolean carrying
    // 2^64-1 overflows before any boolean rule can apply, and reading it as
    // `true` by truncation is exactly the corruption this block exists to
    // catch. This port builds one profile with no feature switches, so
    // [_supportedCapabilities] is complete and this branch is never taken —
    // it is written out anyway so a profile added later needs no new runner.
    // An unrecognized tag contributes nothing (forward compatibility), which
    // is the one place this block's gate differs from `vectors_test.dart`'s.
    final unmet = requires.where(
      (r) =>
          _knownCapabilities.contains(r) && !_supportedCapabilities.contains(r),
    );

    if (unmet.isNotEmpty) {
      rejected++;
      checks++;
      test('$name (${c['group']}) — rejected: no ${unmet.join(", ")}', () {
        final v = _BoolField(fieldId, values.length);
        final dec = sofab.Decoder(v);
        expect(dec.feed(bytes), sofab.DecodeStatus.invalid);
        // A width overflow is INVALID (§5.2.2), never the receiver-cap tier,
        // and the verdict is terminal: one more byte cannot lift it.
        expect(dec.feed(const [0x00]), sofab.DecodeStatus.invalid);
      });
      continue;
    }

    decoded++;
    checks += 2; // decode + re-encode
    test('$name (${c['group']})', () {
      // What the bytes themselves carry, read independently of the JSON: the
      // field id, the element count, and every raw varint at full width.
      final wire = _wireValues(bytes);
      expect(wire.id, fieldId, reason: 'the case states the id its bytes use');
      expect(
        wire.values.length,
        values.length,
        reason: 'expect.values states one entry per element on the wire',
      );

      // ---- A. decode -------------------------------------------------
      // A fresh decoder and a freshly poisoned destination per case: a
      // terminal verdict or a retained buffer must never reach the next one.
      final v = _BoolField(fieldId, values.length);
      expect(sofab.Decoder.decode(bytes, v), want, reason: 'one-shot outcome');
      v.materialize();

      expect(v.calls, 1, reason: 'the field is delivered exactly once');
      if (values.length > 1) {
        expect(
          v.announcedCount,
          values.length,
          reason: 'the header announces the element count the wire carries',
        );
      }
      // Every slot was written (`null` is the poison — no decoder can produce
      // it) and holds exactly the normalized boolean, compared strictly
      // against a real `bool`. Never coerce first: a truthiness wrapper maps a
      // stored `2` onto `true` and destroys the evidence the case carries.
      expect(v.got, values, reason: 'normalized values');
      // ... and the value the codec handed the zero test was the full-width
      // one, so a truncation that happens to stay non-zero is caught too.
      expect(v.raw, wire.values, reason: 'raw values, at full width');

      // The streaming surface, one byte per feed — the finest split there is,
      // and the one that matters for the ten-byte varints of the 2^64-1 cases.
      final v2 = _BoolField(fieldId, values.length);
      final dec = sofab.Decoder(v2);
      var st = dec.feed(const <int>[]);
      for (final b in bytes) {
        st = dec.feed(Uint8List.fromList([b]));
      }
      expect(st, want, reason: 'streaming outcome (one byte per feed)');
      v2.materialize();
      expect(v2.got, values, reason: 'normalized values (streamed)');
      expect(v2.raw, wire.values, reason: 'raw values (streamed)');

      // ---- B. re-encode ----------------------------------------------
      // Written from what the DECODER produced, never from `expect.values`:
      // re-encoding the expectation would match `reencoded_hex` trivially and
      // leave the decode half unverified. The count comes from the decode too.
      final out = sofab.Encoder.encodeToBytes((e) {
        if (v.got.length == 1) {
          e.writeBool(fieldId, v.got[0]!);
        } else {
          // This port has no boolean-array writer; §4.7 makes the element
          // width an API concern that never reaches the wire, so the
          // normalized 0/1 go out through the unsigned-array writer.
          e.writeUnsignedArray(fieldId, [for (final b in v.got) b! ? 1 : 0]);
        }
      });
      // `encodeToBytes` flushes before returning, and an encoder failure in
      // this port is a thrown `SofabException` — reaching this line at all is
      // the success indication.
      expect(
        bytesToHex(out),
        reencoded,
        reason: 'the re-encode is canonical (§4.4), byte for byte',
      );
      expect(out.length, reencoded.length ~/ 2);
    });
  }

  // CORELIB_PLAN §7.2: the run says how much of the block it executed. A file
  // that silently shrank, a gate that skipped the tagged cases, or a runner
  // that only ever ran the scalars is visible here rather than only in a diff.
  test('boolean_tolerant inventory', () {
    stdout.writeln(
      '[boolean_tolerant] ${cases.length} found, '
      '$decoded decoded, $rejected rejected -> $checks checks executed',
    );
    expect(cases.length, decoded + rejected, reason: 'every case was run');
    expect(cases.length, greaterThanOrEqualTo(_minCases));
    expect(decoded, greaterThan(0), reason: 'a run that decodes nothing fails');
    // This port satisfies every tag, so nothing is ever on the reject path.
    expect(rejected, 0, reason: 'this port builds one full-capability profile');
    // Both halves of the rule are under test: at least one scalar case and at
    // least one array case ran. A runner that filtered on a single value would
    // lose the element-level half of §4.4 entirely.
    expect(
      cases.where((c) => ((c['expect'] as Map)['values'] as List).length > 1),
      isNotEmpty,
    );
  });
}

/// The floor the block is known to meet (corelib-c-cpp@main). Not an equality:
/// the block may grow upstream, and a printed `found` is how that is noticed.
const int _minCases = 8;

/// The wire-format capabilities this port implements, in the vocabulary the
/// block's `requires` sets use. Dart builds one profile with no feature
/// switches, so this is the complete list and no case is ever gated out.
const Set<String> _supportedCapabilities = {
  'int64',
  'fixlen',
  'fp64',
  'array',
  'sequence',
};

/// The tags the corpus defines today. A tag outside this set is one the corpus
/// gained later: it contributes nothing to the needed set and the case runs
/// positively, so every port agrees on what a new tag does.
const Set<String> _knownCapabilities = {
  'int64',
  'fixlen',
  'fp64',
  'array',
  'sequence',
  'dynamic_arrays',
  'receiver_caps',
};

sofab.DecodeStatus _outcome(String name) => switch (name) {
  'complete' => sofab.DecodeStatus.complete,
  'incomplete' => sofab.DecodeStatus.incomplete,
  'invalid' => sofab.DecodeStatus.invalid,
  'limit_exceeded' => sofab.DecodeStatus.limitExceeded,
  _ => fail('unknown outcome $name'),
};

/// Stands in for the generated layer that materializes one boolean field.
///
/// It records; it never asserts. An assertion raised inside a decoder callback
/// would be raised from under the codec, where this port turns a throw into a
/// verdict — so what the callback saw is stored and checked after the feed
/// returns.
class _BoolField extends sofab.MessageVisitor {
  _BoolField(this.fieldId, int slots)
    : got = List<bool?>.filled(slots, null),
      raw = List<int?>.filled(slots, null);

  final int fieldId;

  /// The decoded booleans. Poisoned with `null` — the one value no decoder can
  /// write — so a codec that never touches the destination cannot pass the
  /// `[false]` case against a zero-initialized buffer.
  final List<bool?> got;

  /// The raw values the codec handed over, before the zero test.
  final List<int?> raw;

  /// How many times the field arrived.
  int calls = 0;

  /// The element count announced in the array header, or `null` for a scalar.
  int? announcedCount;

  sofab.InlineInt64Array? _dest;

  @override
  void onUnsigned(int id, int value) {
    if (id != fieldId) return;
    calls++;
    raw[0] = value;
    // The explicit test against zero §4.4 demands, where a generated consumer
    // writes it. Anything other than 0 is `true`; nothing is masked first.
    got[0] = value != 0;
  }

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) {
    if (id != fieldId) return null;
    calls++;
    announcedCount = count;
    // Poisoned element storage: a slot the codec leaves untouched fails the
    // raw-value check even where its boolean reading would have been right.
    final d = sofab.InlineInt64Array(count)
      ..storage.fillRange(0, count, _elementPoison);
    _dest = d;
    return d;
  }

  /// Reads the array destination back, after the feed — this is where a
  /// generated consumer applies the zero test to each element.
  void materialize() {
    final d = _dest;
    if (d == null) return;
    for (var i = 0; i < d.length && i < got.length; i++) {
      raw[i] = d[i];
      got[i] = d[i] != 0;
    }
  }

  static const int _elementPoison = 0x55AA55AA55AA55AA;
}

/// The bytes' own account of themselves: the field id, and every value varint
/// at full 64-bit width (as its int64 bit pattern, so 2^64-1 is -1 — what this
/// port's codec and encoder use).
///
/// Read from `serialized_hex` rather than from the JSON expectations, so the
/// raw-value check above is independent of the values the case predicts.
({int id, List<int> values}) _wireValues(Uint8List bytes) {
  var i = 0;
  int varint() {
    var v = 0;
    var shift = 0;
    while (true) {
      final b = bytes[i++];
      v |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return v;
      shift += 7;
    }
  }

  final header = varint();
  final id = header >> 3;
  final type = header & 0x7;
  final values = <int>[];
  if (type == 0x3) {
    final count = varint();
    for (var k = 0; k < count; k++) {
      values.add(varint());
    }
  } else {
    values.add(varint());
  }
  expect(i, bytes.length, reason: 'the case is one field and nothing else');
  return (id: id, values: values);
}
