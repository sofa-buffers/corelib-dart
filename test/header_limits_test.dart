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
/// emits, in the header call that asks for the field's storage —
/// [sofab.MessageVisitor.onString]/[sofab.MessageVisitor.onBlob] for a length,
/// [sofab.MessageVisitor.onUnsignedArray] and its siblings for a count.
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

  if (cases == null) {
    // `header_limits_nested` is a separate top-level block: a vector file
    // without the flat one must not hide whether the nested one is there.
    _nestedSuite(root);
    return;
  }

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

  // `header_limits_nested`: the identical assertion, one or two frames deeper.
  _nestedSuite(root);
}

/// Registers the `header_limits_nested` block, whose absence is a failure
/// rather than a skip.
void _nestedSuite(Map<dynamic, dynamic> root) {
  final nested = (root['header_limits_nested'] as List?)
      ?.cast<Map<String, dynamic>>();

  test('the header_limits_nested block is present', () {
    expect(
      nested,
      isNotNull,
      reason:
          'assets/test_vectors.json predates the header_limits_nested block — '
          'a missing block is a failure here, not a skip',
    );
    expect(nested, isNotEmpty);
  });

  if (nested != null) _nestedBlock(nested);
}

/// The shared `header_limits_nested` block: every assertion the flat block
/// above makes, made again **inside an open sequence**.
///
/// ```text
/// 3e 1e 02 a2 06   then EOF
/// ^^ id 7, wire type 6 — a sequence opens
///    ^^ id 3, wire type 6 — and another inside it
///       ^^ id 0, wire type 2 (fixlen)
///          ^^^^^ length word (100 << 3) | 2  ->  a 100-byte STRING
///                  ... and the message ends, with BOTH frames still open.
/// ```
///
/// Depth is its own axis because the flat block cannot reach it: every case
/// there puts its field at the top level, so a port that binds its ceiling to
/// the top-level scope — and nowhere else — passes the flat block completely
/// while capping nothing a sequence contains. `frames` (outermost first) is the
/// one new key, and the ceiling belongs to the field at the **innermost** depth.
///
/// The truncation here has a **second, independent reason** to read as
/// `incomplete`: the frames never close. That is what makes the negative
/// control below load-bearing rather than decorative — with the ceiling lifted,
/// a decoder that rejected for some unrelated reason (a depth guard, a
/// refusal of unclosed frames) answers the same way it did before, and only
/// that comparison tells it apart from one that consulted the ceiling.
///
/// The leaf is [_Ceiling] — **the same leaf the flat block uses**, unchanged.
/// The two blocks are required to differ in where the field arrives and in
/// nothing else; a second leaf implementation here could make the nested path
/// pass by a mechanism the flat path never uses.
void _nestedBlock(List<Map<String, dynamic>> cases) {
  // The gate is evaluated once, up front, so the block can *report* what it ran
  // and what it gated. The whole value of these cases is that they execute: a
  // capability probe that answered "unsupported" by accident would turn the
  // runner into a green no-op, and `ran + gated == total` is the cheap guard.
  final ran = <Map<String, dynamic>>[];
  final gated = <String, String>{}; // case name -> the tags that gated it

  for (final c in cases) {
    final unmet = _gatedBy(c);
    if (unmet.isEmpty) {
      ran.add(c);
    } else {
      gated[c['name'] as String] = unmet.join(', ');
    }
  }

  final report = gated.isEmpty
      ? ''
      : ' (${gated.entries.map((e) => '${e.key}: no ${e.value}').join('; ')})';

  test('header_limits_nested: ran ${ran.length}, gated ${gated.length} '
      'of ${cases.length}$report', () {
    expect(
      ran.length + gated.length,
      cases.length,
      reason: 'every case is either run or gated, and counted once',
    );
    expect(ran, isNotEmpty, reason: 'a fully gated block tests nothing');
    // A chain builder off by one, or a runner that special-cases one level,
    // hides completely in a block of depth-1 cases. Depth 2 must have run.
    expect(
      ran.where((c) => (c['frames'] as List).length >= 2),
      isNotEmpty,
      reason: 'no depth-2 case ran; `frames` of length 2 is unexercised',
    );
  });

  for (final c in cases) {
    final name = c['name'] as String;
    final frames = (c['frames'] as List).map(jInt).toList();
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
    final unmet = _gatedBy(c);

    /// The ceiling this case configures, fresh per decode surface — the same
    /// construction the flat block makes, because it is the same leaf.
    _Ceiling ceiling() => _Ceiling(
      fieldId,
      schemaMaxlen: schema == null ? -1 : jInt(schema['maxlen']),
      maxStringLen: _cap(limits, 'max_dyn_string_len', sofab.fixlenMax),
      maxBlobLen: _cap(limits, 'max_dyn_blob_len', sofab.fixlenMax),
      maxArrayCount: _cap(limits, 'max_dyn_array_count', sofab.arrayMax),
    );

    test(
      '$name (${c['group']}, frames $frames)',
      () {
        expect(frames, isNotEmpty, reason: 'frames is what this block adds');
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
          sofab.Decoder.decode(bytes, _Frames(frames, one)),
          want,
          reason: 'one-shot outcome',
        );
        // The header word reached the leaf at the INNERMOST depth. Without
        // this, a rejection produced anywhere else on the way down — a depth
        // guard, a malformed-frame path — would read as the ceiling's.
        expect(
          one.headerValue,
          declared,
          reason: 'the leaf ${frames.length} frame(s) down saw the header word',
        );

        // 2. The streaming surface, in the case's own chunking where it states
        //    one. No case in this block carries `chunks` today; the key is
        //    honoured anyway, because the two blocks share a key set.
        final streamed = ceiling();
        final dec = sofab.Decoder(_Frames(frames, streamed));
        var st = dec.feed(const <int>[]);
        final feeds = chunks.isEmpty ? [bytes] : chunks;
        for (var i = 0; i < feeds.length; i++) {
          st = dec.feed(feeds[i]);
          if (i < feeds.length - 1) {
            expect(
              st,
              sofab.DecodeStatus.incomplete,
              reason:
                  'chunk ${i + 1} of ${feeds.length} answered on bytes it had '
                  'not yet been given',
            );
          }
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
        final dec2 = sofab.Decoder(_Frames(frames, perByte));
        var st2 = dec2.feed(const <int>[]);
        for (final b in bytes) {
          st2 = dec2.feed(Uint8List.fromList([b]));
        }
        expect(st2, want, reason: 'streaming outcome (one byte per feed)');

        if (terminal) {
          // §6.3: terminal. The bytes fed are the payload the header promised,
          // so a decoder that resumed would be caught taking them — and the
          // question is put to the decoder again rather than to a stored
          // status, which a decoder that had moved on would still answer.
          final payload = Uint8List(16);
          expect(dec.feed(payload), want, reason: 'terminal: re-raises');
          expect(dec.feed(payload), want, reason: 'terminal: and stays');
          expect(dec2.feed(payload), want);
          expect(dec2.feed(const <int>[]), want);

          // "Rejected, never clamped" (§6.2.1), checked AFTER the payload was
          // offered so a late materialization is caught too: the ceiling fires
          // in the header call, before storage is chosen, so no destination was
          // ever handed over — a port that truncated to the cap would show one
          // here, holding the clamped length.
          for (final leaf in [one, streamed, perByte]) {
            expect(
              leaf.destination,
              isNull,
              reason: 'no storage was bound for a rejected header',
            );
          }
        } else {
          // The in-cap control. Not filler: the same shape at a size the
          // ceiling admits must still answer `incomplete`, or a port that
          // rejects everything nested would pass all four rejections while
          // being badly broken.
          expect(want, sofab.DecodeStatus.incomplete);
          // And `incomplete` here is liftable in BOTH its reasons (§5.2.1):
          // the payload the header promised, then one sequence-end marker per
          // open frame, completes the message. This is after the case's own
          // answer has been taken, so the case itself is still fed verbatim.
          expect(
            dec2.feed(Uint8List(declared)),
            sofab.DecodeStatus.incomplete,
            reason: 'the payload arrives, but the frames are still open',
          );
          for (var i = 0; i < frames.length; i++) {
            st2 = dec2.feed(
              // id bits are ignored on a close; the low three are the type.
              Uint8List.fromList([sofab.WireType.sequenceEnd]),
            );
          }
          expect(
            st2,
            sofab.DecodeStatus.complete,
            reason: 'the control is liftable — that is what INCOMPLETE means',
          );
          expect(
            perByte.destinationLength,
            declared,
            reason: 'the payload landed in the leaf at the innermost depth',
          );
        }
      },
      skip: unmet.isEmpty
          ? null
          : 'this port declares no ${unmet.join(", ")} capability',
    );
  }

  group('negative control: the same nested bytes with the ceiling lifted', () {
    // The block's load-bearing pass. These cases end with a frame open, so a
    // decoder has a second, fully independent reason to answer `incomplete` —
    // and, worse, a decoder that rejects unclosed frames (or trips a depth
    // guard) produces a rejection that LOOKS like the ceiling's and passes the
    // forward pass while never having consulted a ceiling at all.
    //
    // Lifting the ceiling — the same KIND the case states, a schema bound for a
    // schema case and a receiver cap for a limits case — is what separates the
    // two: if the answer does not change, the ceiling was not what rejected.
    const lifted = 65536; // far above every `declared` here, far below a heap.

    final rejections = ran
        .where((c) => (c['expect'] as Map)['outcome'] != 'incomplete')
        .toList();
    // A case declaring more than the lifted ceiling could not be checked this
    // way (lifting past it is the allocation §6.2.1 exists to prevent). The
    // flat block has one such case, at 1 GiB; this block has none, so the
    // control covers every rejection it gates in — and says so by counting.
    final checkable = rejections
        .where((c) => jInt(c['declared']) < lifted)
        .toList();
    var checked = 0;

    for (final c in checkable) {
      final name = c['name'] as String;
      final frames = (c['frames'] as List).map(jInt).toList();
      final fieldId = jInt(c['field_id']);
      final declared = jInt(c['declared']);
      final limits = (c['limits'] as Map?)?.cast<String, dynamic>();
      final schema = (c['schema'] as Map?)?.cast<String, dynamic>();
      final want = _outcome((c['expect'] as Map)['outcome'] as String);
      final bytes = hexToBytes(c['serialized'] as String);

      // Lift whichever ceiling the case states, and only that one: a schema
      // case whose receiver cap were lifted instead would (rightly) not change
      // its answer, and a runner lifting both would let the cap's absence
      // explain a schema case's fallback. Whichever single cap name the case
      // carries is the one raised — read generically, never assumed.
      int liftedCap(String key, int fallback) =>
          limits != null && limits[key] != null ? lifted : fallback;

      _Ceiling ceiling() => _Ceiling(
        fieldId,
        schemaMaxlen: schema == null ? -1 : lifted,
        maxStringLen: liftedCap('max_dyn_string_len', sofab.fixlenMax),
        maxBlobLen: liftedCap('max_dyn_blob_len', sofab.fixlenMax),
        maxArrayCount: liftedCap('max_dyn_array_count', sofab.arrayMax),
      );

      test('$name answers differently once its ceiling is lifted', () {
        final one = ceiling();
        expect(
          sofab.Decoder.decode(bytes, _Frames(frames, one)),
          isNot(want),
          reason:
              'one-shot: $want survived a ceiling of $lifted over '
              '$declared, so it was not the ceiling that produced it',
        );
        expect(one.headerValue, declared, reason: 'the leaf was still reached');

        final perByte = ceiling();
        final dec = sofab.Decoder(_Frames(frames, perByte));
        var st = dec.feed(const <int>[]);
        for (final b in bytes) {
          st = dec.feed(Uint8List.fromList([b]));
        }
        expect(st, isNot(want), reason: 'streaming, ceiling lifted');
        checked++;
      });
    }

    test('the control pass examined every liftable rejection', () {
      // Trap 3: a control loop that `continue`s through every iteration is
      // green and covers nothing. The count is what makes it say so.
      expect(
        checked,
        checkable.length,
        reason: 'the control ran on every rejection it selected',
      );
      expect(
        checkable.length,
        rejections.length,
        reason:
            'every rejection this block runs is liftable; if a future case '
            'declares more than $lifted it must be named here, not dropped',
      );
      expect(checked, greaterThan(0), reason: 'a control that checks nothing');
    });
  });
}

/// The `frames` chain: a visitor that descends exactly the sequence ids the
/// case names, outermost first, and hands the innermost scope to the leaf.
///
/// Any other id at any depth is answered with `null` — skipped, as §4.2 item 4
/// asks, and as generated code does for a field it has no place for.
class _Frames extends sofab.MessageVisitor {
  _Frames(this._frames, this._leaf);

  /// The remaining chain; `_frames.first` is the id expected at this depth.
  final List<int> _frames;
  final sofab.MessageVisitor _leaf;

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    if (id != _frames.first) return null;
    return _frames.length == 1 ? _leaf : _Frames(_frames.sublist(1), _leaf);
  }
}

/// The tags of [c] this port cannot satisfy — an empty result means the case
/// runs.
///
/// An unsatisfied tag is a **skip** in these two blocks, for every tag and not
/// just the profile one: a build that cannot represent the construct would
/// reject the bytes for an unrelated reason and appear to pass while testing
/// nothing. An **unrecognized** tag is satisfied, so a newer vector file stays
/// runnable by an older runner; the ran/gated report is what keeps that
/// leniency from quietly disabling the block.
Iterable<String> _gatedBy(Map<String, dynamic> c) =>
    ((c['requires'] as List?) ?? const [])
        .cast<String>()
        .where(_knownCapabilities.contains)
        .where((r) => !_supportedCapabilities.contains(r));

/// The `requires` vocabulary these blocks use today — the set a tag must be in
/// before its absence from [_supportedCapabilities] gates a case.
const Set<String> _knownCapabilities = {
  'int64',
  'fixlen',
  'array',
  'sequence',
  'receiver_caps',
};

/// The capabilities this port implements, in the vocabulary the two blocks'
/// `requires` sets use. The wire-construct tags are the same ones
/// `vectors_test.dart` declares — including `sequence`, which only the nested
/// block asks for, and which this port satisfies unconditionally because it
/// builds one profile with no feature switches. `receiver_caps` is the
/// **profile** tag, and this port declares it because its generated layer
/// carries §6.2.1 caps distinct from schema bounds — the pair of statements
/// `schema_bound_limit_test.dart` pins, and [_Ceiling] below restates for these
/// bytes.
const Set<String> _supportedCapabilities = {
  'fixlen',
  'array',
  'int64',
  'sequence',
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
/// has to remember. Both statements are made in the header call, which is made
/// at the length/count word, before storage is chosen and before truncation is
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
  /// verdict. It also says the leaf was *reached*, which is the difference
  /// between the ceiling rejecting and something on the way down doing it.
  int? headerValue;

  /// The storage this leaf handed the codec, or `null` when it handed over
  /// none — the "rejected, never clamped" half of §6.2.1 in one field. A
  /// ceiling fires in the header call, before a destination is chosen, so a
  /// rejected field must leave this unset; a port that truncated to the cap
  /// would leave a destination holding the clamped size.
  Object? destination;

  /// [destination]'s logical length, or `null` when nothing was bound.
  int? get destinationLength => switch (destination) {
    final sofab.InlineBytes d => d.length,
    final sofab.InlineInt64Array d => d.length,
    final sofab.InlineFloat32Array d => d.length,
    final sofab.InlineFloat64Array d => d.length,
    _ => null,
  };

  /// Records what is handed over, and hands it over.
  T? _bind<T extends Object>(T? dest) {
    destination = dest;
    return dest;
  }

  /// The ceilings, applied in the header call before any storage is chosen.
  void _judge(int id, int n, int cap) {
    if (id != fieldId) return;
    headerValue = n;
    if (schemaMaxlen >= 0) {
      if (n > schemaMaxlen) invalidate();
      return;
    }
    if (n > cap) limitExceeded();
  }

  /// Storage for anything this block could actually deliver, and a decline above
  /// that. Generated code would hand over the caller's own storage here; the
  /// difference matters only for the amplification case, whose header claims a
  /// gigabyte that no message in the block carries — and the decline comes
  /// *after* the ceiling above, so it changes no verdict, only what an
  /// implementation whose ceiling is momentarily broken (the failing-first
  /// proof) is asked to allocate.
  static const int _willingToHold = 1 << 20;

  bool _hold(int n) => n <= _willingToHold;

  @override
  sofab.InlineString? onString(int id, int length) {
    _judge(id, length, maxStringLen);
    return _bind(_hold(length) ? sofab.InlineString(length) : null);
  }

  @override
  sofab.InlineBytes? onBlob(int id, int length) {
    _judge(id, length, maxBlobLen);
    return _bind(_hold(length) ? sofab.InlineBytes(length) : null);
  }

  @override
  sofab.InlineInt64Array? onUnsignedArray(int id, int count) {
    _judge(id, count, maxArrayCount);
    return _bind(_hold(count) ? sofab.InlineInt64Array(count) : null);
  }

  @override
  sofab.InlineInt64Array? onSignedArray(int id, int count) {
    _judge(id, count, maxArrayCount);
    return _bind(_hold(count) ? sofab.InlineInt64Array(count) : null);
  }

  @override
  sofab.InlineFloat32Array? onFp32Array(int id, int count) {
    _judge(id, count, maxArrayCount);
    return _bind(_hold(count) ? sofab.InlineFloat32Array(count) : null);
  }

  @override
  sofab.InlineFloat64Array? onFp64Array(int id, int count) {
    _judge(id, count, maxArrayCount);
    return _bind(_hold(count) ? sofab.InlineFloat64Array(count) : null);
  }
}
