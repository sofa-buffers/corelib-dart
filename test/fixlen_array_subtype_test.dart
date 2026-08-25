import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// CORELIB_PLAN §4.8 / MESSAGE_SPEC §7.3 — the fixlen-array decode order
/// (Crucible finding **F-0042**, corelib-dart#23).
///
/// A fixlen array carries **two** words: `element_count`, then the `fixlen_word`
/// (element subtype + per-element byte length). The order in which they are acted
/// on is normative:
///
///  1. read `element_count`; enforce only the **format** ceiling `ARRAY_MAX`,
///     allocating nothing on the strength of it;
///  2. read the `fixlen_word`; EOF before or inside it is **INCOMPLETE**;
///  3. validate the word as a **format** matter — only fp32/4 and fp64/8 are legal
///     elements — anything else is INVALID and is *not* routed to a §7.3 skip;
///  4. only now offer the field, via `onArrayBegin(id, kind, count)` with
///     `kind` ∈ {[sofab.ArrayKind.fp32], [sofab.ArrayKind.fp64]};
///  5. a consumer whose declared element type **contradicts** `kind` skips the
///     field (§7.3) and MUST NOT apply the schema `count` bound — the field was
///     never this array's value. A matching `kind` gets the bound;
///  6. a consumer whose declared element type MATCHES but which declares no
///     `count` weighs the receiver **policy** cap instead — `limitExceeded`,
///     never `invalid`, and still ahead of the payload allocation it prevents.
///     It is stated in the very same hook, as the *else* of the schema bound,
///     which is what keeps the two from ever both applying (CORELIB_PLAN §6.2.1
///     — covered in `schema_bound_limit_test.dart`). The decoder holds no cap
///     of its own.
///
/// The corelib carries no verdict logic of its own here: it only decides *when*
/// the hook fires and *what kind* it carries. The generated, schema-bound
/// consumer is modelled by [_Gen] below, and the combined verdict by
/// [_Gen.verdict] — exactly as `header_callback_test.dart` does for the §5.2
/// anti-folding rule.
///
/// Vectors are the shared F-0042 isolates: `arrays` (id 100) → `nested` (id 10)
/// → id 0, declared `array<fp32, count 5>`. `20` is the `fixlen_word` for fp32
/// (4 B), `41` for fp64 (8 B) — the contradicting subtype.
void main() {
  group('F-0042: the schema count bound waits for the element subtype', () {
    test('row 1 — count 3, fp64 word at an fp32 slot → skip, ACCEPT', () {
      final v = _run(_fixArray(count: '03', word: _fp64, elems: 3));
      expect(v.status, sofab.DecodeStatus.complete);
      expect(v.inv, isFalse, reason: 'a skipped field is not schema-validated');
      expect(
        v.field,
        isNull,
        reason: 'the declared fp32 field keeps its default',
      );
      expect(v.begins, ['0:fp64:3']);
    });

    test('row 2 — count 8 > 5 BUT fp64 word → skip, no bound, ACCEPT', () {
      // THE PRIMARY ROW. The subtype contradicts the declared fp32 first, so the
      // field is skipped and its element count is not this array's count.
      final v = _run(_fixArray(count: '08', word: _fp64, elems: 8));
      expect(v.status, sofab.DecodeStatus.complete);
      expect(v.inv, isFalse);
      expect(v.field, isNull);
      expect(v.begins, ['0:fp64:8']);
    });

    test('row 3 — count 8 > 5 with a MATCHING fp32 word → INVALID', () {
      // CONTROL. The bound is being reordered, not weakened.
      final v = _run(_fixArray(count: '08', word: _fp32, elems: 8));
      expect(v.verdict, sofab.DecodeStatus.invalid);
      expect(v.begins, ['0:fp32:8']);
    });

    test('row 4 — EOF between the count and the fixlen_word → INCOMPLETE', () {
      // SECOND PRIMARY ROW. The decoder cannot yet know which field this is, so
      // §5.2 does not reach INVALID — and the hook must not have fired.
      final v = _run(_fixArray(count: '08', word: '', closed: false));
      expect(v.verdict, sofab.DecodeStatus.incomplete);
      expect(v.inv, isFalse);
      expect(v.begins, isEmpty);
    });

    test('row 5 — count 8, fp32 word, EOF before any payload → INVALID', () {
      // CONTROL. Once the subtype is known and matches, an over-count is
      // malformed regardless of what follows: INVALID dominates INCOMPLETE.
      final v = _run(_fixArray(count: '08', word: _fp32, closed: false));
      expect(v.verdict, sofab.DecodeStatus.invalid);
      expect(v.begins, ['0:fp32:8']);
    });

    test('row 6 — count 3, fp32 word, full payload → ACCEPT', () {
      final v = _run(_fixArray(count: '03', word: _fp32, elems: 3));
      expect(v.verdict, sofab.DecodeStatus.complete);
      expect(v.begins, ['0:fp32:3']);
      expect(v.field, isNotNull);
      expect(v.field!.length, 3);
    });

    test('row 6 — round-trips byte-identically', () {
      final hex = _fixArray(count: '03', word: _fp32, elems: 3);
      // a6 06 | 56 | 05 | 03 | 20 | 12 payload bytes | 07 07
      expect(hex, 'a606560503200000000000000000000000000707');
      final v = _run(hex);
      final out = sofab.Encoder.encodeToBytes((e) {
        e.beginSequenceLazy(100);
        e.beginSequenceLazy(10);
        e.writeFp32Array(0, v.field!);
        e.endSequence();
        e.endSequence();
      });
      expect(bytesToHex(out), hex);
    });
  });

  group('F-0042: the call-site move must not lose the zero-count case', () {
    test('count 0 with an fp64 word at an fp32 slot → skip, ACCEPT', () {
      // A zero-count fixlen array still carries its fixlen_word (§4.8), so the
      // hook fires exactly once, with the real kind, and no payload is read.
      final v = _run(_fixArray(count: '00', word: _fp64));
      expect(v.verdict, sofab.DecodeStatus.complete);
      expect(v.begins, ['0:fp64:0']);
      expect(v.field, isNull);
    });

    test('count 0 with a matching fp32 word → ACCEPT, empty array', () {
      final v = _run(_fixArray(count: '00', word: _fp32));
      expect(v.verdict, sofab.DecodeStatus.complete);
      expect(v.begins, ['0:fp32:0']);
      expect(v.field, isNotNull);
      expect(v.field, isEmpty);
    });

    test(
      'an empty fp32 array stays distinguishable from an empty fp64 one',
      () {
        final asFp32 = _run(_fixArray(count: '00', word: _fp32)).begins;
        final asFp64 = _run(_fixArray(count: '00', word: _fp64)).begins;
        expect(asFp32, isNot(asFp64));
      },
    );
  });

  group('F-0042: format violations stay INVALID, they are not §7.3 skips', () {
    // Each of these also *contradicts* the declared fp32, so each is the exact
    // over-correction this fix could invite: they must stay malformed bytes
    // (judged before the hook fires), not become a §7.3 skip.
    const cases = <String, String>{
      'string subtype': '22', // subtype 2 (string) / elem_len 4
      'blob subtype': '23', // subtype 3 (blob) / elem_len 4
      'reserved subtype': '24', // subtype 4 / elem_len 4
      'fp32 with elem_len != 4': '40', // subtype 0 (fp32) / elem_len 8
      'fp64 with elem_len != 8': '21', // subtype 1 (fp64) / elem_len 4
    };
    cases.forEach((name, word) {
      test('$name in a fixlen array → INVALID, hook never fires', () {
        final v = _run(_fixArray(count: '03', word: word, elems: 3));
        expect(v.status, sofab.DecodeStatus.invalid);
        expect(v.begins, isEmpty);
      });
    });
  });

  group('F-0042: what did NOT move', () {
    test('ARRAY_MAX still fires on the count word, before the word', () {
      // count = 2^31 (varint 80 80 80 80 08) — a *format* ceiling, so INVALID
      // (never INCOMPLETE), decided before the fixlen_word is even read and with
      // nothing allocated.
      final v = _run(_fixArray(count: '8080808008', word: '', closed: false));
      expect(v.status, sofab.DecodeStatus.invalid);
      expect(v.begins, isEmpty);
    });

    test('a receiver cap is limitExceeded, never folded into invalid', () {
      // A receiver *policy* cap (CORELIB_PLAN §6.2.1) is its own outcome, and it
      // is decided behind the fixlen_word and inside the hook — because whether
      // this count is even this field's is a question about the element kind
      // (§7.3), and because a schema-bounded field is exempt from the cap
      // altogether. id 2 is the field the schema leaves unbounded.
      //
      // Header `15` = (2 << 3) | ARRAY_FIXLEN.
      final v = _run(
        _fixArray(count: '03', word: _fp32, elems: 3, hdr: '15'),
        cap: 2,
      );
      expect(v.status, sofab.DecodeStatus.limitExceeded);
      expect(v.inv, isFalse);
      expect(v.begins, ['2:fp32:3']);
    });

    test('the cap stays off the field the schema bounds', () {
      // The same three elements at id 0, which declares `count: 5`. §6.2.1: a
      // cap "MUST NOT be applied to a field the schema already bounds" — so a
      // cap of 2 must not touch it, and the message decodes.
      final v = _run(_fixArray(count: '03', word: _fp32, elems: 3), cap: 2);
      expect(v.status, sofab.DecodeStatus.complete);
      expect(v.inv, isFalse);
      expect(v.field, isNotNull);
    });

    test('an fp64 header at the unbounded id is skipped, not capped', () {
      // §7.3 again, on the cap side: the element kind contradicts what id 2
      // declares, so the field was never its value and no bound of its own —
      // schema or policy — is measured against it.
      final v = _run(
        _fixArray(count: '03', word: _fp64, elems: 3, hdr: '15'),
        cap: 2,
      );
      expect(v.status, sofab.DecodeStatus.complete);
      expect(v.begins, ['2:fp64:3']);
    });

    test('a skipped fixlen array still fires no hook at all', () {
      final v = _run(_fixArray(count: '03', word: _fp32, elems: 3), skip: true);
      expect(v.status, sofab.DecodeStatus.complete);
      expect(v.begins, isEmpty);
      expect(v.inv, isFalse);
    });
  });

  group('F-0042: integer arrays are untouched', () {
    test('unsigned array header at an fp32 slot: kind unsigned, no bound', () {
      // `03` = ARRAY_UNSIGNED at id 0, whose declared type is array<fp32>. The
      // wire type contradicts the schema, so §7.3 skips the field and the count
      // bound must not apply even though count 8 > 5 — the same reasoning as
      // row 2, one step earlier on the wire.
      final v = _run(_scoped('0308${'00' * 8}'));
      expect(v.verdict, sofab.DecodeStatus.complete);
      expect(v.begins, ['0:unsigned:8']);
      expect(v.field, isNull);
    });

    test('signed array header reports ArrayKind.signed', () {
      // `04` = ARRAY_SIGNED at id 0, two zig-zag elements.
      final v = _run(_scoped('04020002'));
      expect(v.verdict, sofab.DecodeStatus.complete);
      expect(v.begins, ['0:signed:2']);
    });

    test(
      'an integer array over its own bound is still INVALID at the header',
      () {
        // id 15 (header 0x7b) declared array<unsigned, count 4>: the bound still
        // applies immediately after the count word, and still dominates the
        // truncated tail (§5.2).
        final v = _run('7b060102', intId: 15, intBound: 4);
        expect(v.verdict, sofab.DecodeStatus.invalid);
        expect(v.begins, ['15:unsigned:6']);
      },
    );
  });

  test('§7.4 — a correct earlier occurrence survives a mistyped later one', () {
    // Two ARRAY_FIXLEN occurrences at id 0: a valid fp32 one, then an fp64 one.
    // The second is skipped under §7.3, and "an occurrence skipped under §7.3 is
    // not an occurrence" — it must not clear or replace the first one's value.
    final v = _run(_scoped('0503$_fp32${'00' * 12}0508$_fp64${'00' * 64}'));
    expect(v.verdict, sofab.DecodeStatus.complete);
    expect(v.begins, ['0:fp32:3', '0:fp64:8']);
    expect(v.field, isNotNull);
    expect(v.field!.length, 3);
  });
}

/// `fixlen_word` for fp32 elements: `(4 << 3) | 0`.
const String _fp32 = '20';

/// `fixlen_word` for fp64 elements: `(8 << 3) | 1`.
const String _fp64 = '41';

/// Wraps [body] in the two sequence headers the isolates use — `arrays` (id 100,
/// header `a6 06`) → `nested` (id 10, header `56`) — and closes both with `07 07`
/// unless [closed] is false (a truncated vector).
String _scoped(String body, {bool closed = true}) =>
    'a60656$body${closed ? '0707' : ''}';

/// An ARRAY_FIXLEN field at id 0 (header `05`) inside that scope: [count] varint,
/// then the [word] (empty = the vector is cut before it), then [elems] all-zero
/// elements of the width [word] declares.
String _fixArray({
  required String count,
  required String word,
  int elems = 0,
  bool closed = true,
  String hdr = '05',
}) {
  final width = word == _fp64 ? 8 : 4;
  return _scoped('$hdr$count$word${'00' * (elems * width)}', closed: closed);
}

/// Runs [hex] through **both** decode paths — the one-shot contiguous decoder and
/// the streaming state machine fed one byte at a time (worst-case suspend/resume)
/// — asserts they agree on every observable, and returns the shared result.
_Gen _run(
  String hex, {
  int cap = arrayMaxCap,
  bool skip = false,
  int intId = -1,
  int intBound = 0,
}) {
  final bytes = hexToBytes(hex);

  final contig = _Gen(skip: skip, intId: intId, intBound: intBound, cap: cap);
  contig.status = sofab.Decoder.decode(bytes, contig);

  final stream = _Gen(skip: skip, intId: intId, intBound: intBound, cap: cap);
  final dec = sofab.Decoder(stream);
  var last = sofab.DecodeStatus.complete;
  for (final b in bytes) {
    last = dec.feed([b]);
  }
  if (bytes.isEmpty) last = dec.feed(const []);
  stream.status = last;

  expect(
    stream.status,
    contig.status,
    reason: 'both paths must agree (status)',
  );
  expect(
    stream.inv,
    contig.inv,
    reason: 'both paths must agree (INVALID flag)',
  );
  expect(stream.begins, contig.begins, reason: 'both paths must agree (hooks)');
  expect(
    stream.field?.length,
    contig.field?.length,
    reason: 'both paths must agree (materialized field)',
  );
  return contig;
}

/// Stands in for the generated, schema-bound consumer of `array<fp32, count 5>`
/// at id 0 (inside `arrays.nested`): it applies the `count` bound **only** in the
/// arm matching the declared element kind, and otherwise lets the field be
/// skipped — which is exactly the shape sofabgen emits once `onArrayBegin`
/// carries the kind.
/// The loosest a receiver cap gets: the format ceiling (§6.2.1 admits no
/// unlimited mode, so there is nothing looser to spell).
const int arrayMaxCap = sofab.arrayMax;

class _Gen extends sofab.MessageVisitor {
  _Gen({
    this.skip = false,
    this.intId = -1,
    this.intBound = 0,
    this.cap = arrayMaxCap,
  });

  /// The deployment's `max_dyn_array_count`, as generated code would carry it.
  /// It governs [_unboundedId] and nothing else: §6.2.1 forbids applying it to
  /// [_declaredId], which the schema bounds.
  final int cap;

  /// Refuse to read the array at all (models a field the schema does not know).
  final bool skip;

  /// An extra integer-array field id with its own bound, for the control tests.
  final int intId;
  final int intBound;

  static const int _declaredId = 0;
  static const sofab.ArrayKind _declaredKind = sofab.ArrayKind.fp32;
  static const int _declaredCount = 5;

  /// A second `array<fp32>` field the schema declares with NO `count`, so the
  /// receiver cap is what governs it.
  static const int _unboundedId = 2;

  /// Sticky INVALID flag, as the generated visitor keeps (§5.2 anti-folding).
  bool inv = false;

  /// Every `onArrayBegin` as `id:kind:count`, in call order.
  final List<String> begins = <String>[];

  /// The declared field's materialized value; `null` = still at its default.
  Float32List? field;

  /// The status the decoder itself returned.
  sofab.DecodeStatus status = sofab.DecodeStatus.complete;

  /// The verdict the generated code reports: a sticky INVALID dominates.
  sofab.DecodeStatus get verdict => inv ? sofab.DecodeStatus.invalid : status;

  bool _matched = false;

  @override
  bool shouldRead(int id, int type) => !skip;

  @override
  void onArrayBegin(int id, sofab.ArrayKind kind, int count) {
    begins.add('$id:${kind.name}:$count');
    if (id == intId) {
      if (kind == sofab.ArrayKind.unsigned && count > intBound) inv = true;
      return;
    }
    if (id == _unboundedId) {
      // Declared, but with no `count`: the receiver cap governs, and its breach
      // is a policy rejection rather than INVALID (§6.2.1, §6.3). Gated on the
      // element kind for the same §7.3 reason as the bounded field below.
      if (kind == _declaredKind && count > cap) limitExceeded();
      return;
    }
    if (id != _declaredId) return;
    // §7.3: a header of the wrong element kind is not this field's value, so it
    // is skipped and the schema `count` bound MUST NOT be applied to it.
    _matched = kind == _declaredKind;
    if (!_matched) return;
    if (count > _declaredCount) inv = true;
  }

  @override
  void onFp32Array(int id, Float32List values) {
    if (id == _declaredId && _matched) field = values;
  }

  // The kinds that never match the declared fp32 field are simply dropped.
  @override
  void onFp64Array(int id, Float64List values) {}
  @override
  void onUnsignedArray(int id, Int64List values) {}
  @override
  void onSignedArray(int id, Int64List values) {}
}
