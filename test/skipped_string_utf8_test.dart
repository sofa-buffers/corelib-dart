import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// Regression suite for Crucible finding **F-0038** (corelib-dart#22): strict
/// UTF-8 validation must fire **only** where a `string` is materialized — read
/// into a declared destination — and never on a payload the consumer is
/// skipping, whether it is skipped because the field id is unknown to the
/// schema (CORELIB_PLAN §6.4, *"skipped fields are never validated"*) or
/// because the header's wire type/subtype contradicts the schema
/// (MESSAGE_SPEC §7.3, which routes to the same skip).
///
/// The corelib half of the fix is [sofab.MessageVisitor.onStringBytes]: the
/// decoder hands the **raw wire bytes** to the destination instead of
/// validating and transcoding them itself, because a Dart `String` cannot carry
/// invalid bytes without the lossy U+FFFD substitution §6.4 forbids outright.
/// The schema half lives in generated code, which resolves the destination
/// first and validates only inside a matched arm.
///
/// So these tests drive the decoder through [_Probe] — a hand-written stand-in
/// for that generated code, modelling Crucible's `probe` schema (declared ids
/// 0-7, 10, 100, 200, 201, 202; `nested.str` = id 10 → id 2 maxlen 32;
/// `string_array` = id 200, element id = index, maxlen 64; `struct_array` =
/// id 202 → element sequence → id 1 maxlen 16). Every vector is asserted
/// against the one-shot decoder **and** every chunk split of the streaming one:
/// §6.4 makes a chunk boundary verdict-neutral.
void main() {
  group('F-0038 · a skipped `string` is never UTF-8-validated', () {
    // ---- MEASURED: the finding, and the §7.3 shape of the same root cause ---

    test('V1 · unknown id 9 carrying a lone continuation byte → COMPLETE', () {
      // 4a  header (9<<3)|2      -> id 9, wire type FIXLEN
      // 0a  fixlen_word (1<<3)|2 -> length 1, subtype STRING
      // 8a  payload              -> a lone continuation byte, invalid UTF-8
      // Id 9 is not declared, so the payload is a length jump: never inspected.
      expectVerdict('4a 0a 8a', sofab.DecodeStatus.complete, events: []);
    });

    test('V2 · §7.3 mistyped struct_array element slot → COMPLETE', () {
      // d6 0c  id 202 (struct_array), SEQUENCE_START
      // 02     id 0 (element index 0), FIXLEN — but element 0 is declared a
      //        struct, i.e. a SEQUENCE, so the wire type contradicts the schema
      // 12     fixlen_word (2<<3)|2 -> length 2, subtype STRING
      // ff ff  invalid UTF-8
      // 07     SEQUENCE_END
      // §7.3: skipped exactly as an unknown id is, and MUST NOT be INVALID. The
      // array materializes with no elements at all.
      expectVerdict(
        'd6 0c 02 12 ff ff 07',
        sofab.DecodeStatus.complete,
        events: ['SEQ:202', 'END'],
      );
    });

    // ---- MEASURED CONTROLS: they isolate the axis ------------------------

    test('C2 · same unknown id, VALID payload "A" → COMPLETE', () {
      // Rules out the unknown id itself: an unknown string is skipped fine.
      expectVerdict('4a 0a 41', sofab.DecodeStatus.complete, events: []);
    });

    test('C3 · same 0x8a byte at subtype BLOB → COMPLETE', () {
      // 0b = (1<<3)|3 -> length 1, subtype BLOB. Rules out the byte: only the
      // `string` subtype ever triggered the defect, and a blob is never
      // UTF-8-validated on any path.
      expectVerdict('4a 0b 8a', sofab.DecodeStatus.complete, events: []);
    });

    test('C1 · the same byte in DECLARED nested.str → INVALID', () {
      // 56 SEQUENCE_START id 10 · 12 FIXLEN id 2 · 0a len 1 STRING · 8a · 07
      // THE load-bearing control: a materialized invalid-UTF-8 string is still
      // INVALID. If this flips to COMPLETE the check was deleted, not moved.
      expectVerdict(
        '56 12 0a 8a 07',
        sofab.DecodeStatus.invalid,
        // The sticky schema flag does not abort the walk — the sequence still
        // closes normally; only the reported verdict changes.
        events: ['SEQ:10', 'END'],
      );
    });

    // ---- DERIVED: framing must stay on the skip path (the F-0012 half) ----

    test('reserved fixlen subtype 0x4 at a SKIPPED id → INVALID', () {
      // 0c = (1<<3)|4 -> subtype 0x4, reserved. CORELIB_PLAN §4.6: a decoder
      // MUST reject a fixlen field carrying a reserved subtype, skip or not.
      expectVerdict('4a 0c 8a', sofab.DecodeStatus.invalid);
    });

    test('length above FIXLEN_MAX at a SKIPPED id → INVALID', () {
      final word = <int>[];
      _writeVarint(
        word,
        ((sofab.fixlenMax + 1) << 3) | sofab.FixlenType.string,
      );
      expectBytes(
        Uint8List.fromList([0x4a, ...word]),
        sofab.DecodeStatus.invalid,
      );
    });

    test('varint over 64 bits at a SKIPPED id → INVALID', () {
      // An 11-byte header varint: over-long, rejected before any payload.
      expectBytes(
        Uint8List.fromList([
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0xff,
          0x7f,
        ]),
        sofab.DecodeStatus.invalid,
      );
    });

    test('nesting past MAX_DEPTH is still INVALID', () {
      final b = <int>[];
      for (var i = 0; i <= sofab.maxDepth; i++) {
        b.add(0x06); // SEQUENCE_START id 0
      }
      expectBytes(Uint8List.fromList(b), sofab.DecodeStatus.invalid);
    });

    test('truncated SKIPPED string is INCOMPLETE, never A and never R', () {
      // 4a id 9 FIXLEN · 12 length 2 STRING · ff — one payload byte of two.
      // The skip still honours the declared length (§5.2 anti-folding), and the
      // stray 0xff must not be inspected at all.
      expectVerdict('4a 12 ff', sofab.DecodeStatus.incomplete);
    });

    test('a skipped string advances by EXACTLY `length` bytes', () {
      // ... 8a then 00 2a = header id 0 unsigned, value 42 -> probe.u8 = 42.
      // A fix that early-returns without advancing desynchronizes the stream.
      expectVerdict(
        '4a 0a 8a 00 2a',
        sofab.DecodeStatus.complete,
        events: ['U:0:42'],
      );
    });

    // ---- DERIVED: the validator itself must not be weakened --------------

    test('overlong C0 80 at a SKIPPED id → COMPLETE', () {
      expectVerdict('4a 12 c0 80', sofab.DecodeStatus.complete, events: []);
    });

    test('overlong C0 80 in DECLARED nested.str → INVALID', () {
      // The Modified-UTF-8 NUL. Relocating the call must not downgrade the
      // validator to a byte-range shortcut.
      expectVerdict(
        '56 12 12 c0 80 07',
        sofab.DecodeStatus.invalid,
        events: ['SEQ:10', 'END'],
      );
    });

    test('surrogate U+D800 (ed a0 80): skipped → A, declared → R', () {
      expectVerdict('4a 1a ed a0 80', sofab.DecodeStatus.complete, events: []);
      expectVerdict(
        '56 12 1a ed a0 80 07',
        sofab.DecodeStatus.invalid,
        events: ['SEQ:10', 'END'],
      );
    });

    test('above U+10FFFF (f5 80 80 80): skipped → A, declared → R', () {
      expectVerdict(
        '4a 22 f5 80 80 80',
        sofab.DecodeStatus.complete,
        events: [],
      );
      expectVerdict(
        '56 12 22 f5 80 80 80 07',
        sofab.DecodeStatus.invalid,
        events: ['SEQ:10', 'END'],
      );
    });

    test('embedded U+0000 stays VALID at a materialized position', () {
      // §6.4: a bare NUL is well-formed UTF-8 and the validator MUST NOT reject
      // it — while `C0 80`, its Modified-UTF-8 spelling, stays rejected above.
      expectVerdict(
        '56 12 12 41 00 07',
        sofab.DecodeStatus.complete,
        events: ['SEQ:10', 'STR:2:A\u0000', 'END'],
      );
    });

    // ---- the other two materialized string destinations ------------------

    test('string_array element rejects invalid UTF-8', () {
      // c6 0c SEQUENCE_START id 200 · 02 FIXLEN id 0 (index 0) · 0a len 1
      // STRING · 8a · 07
      expectVerdict(
        'c6 0c 02 0a 8a 07',
        sofab.DecodeStatus.invalid,
        events: ['SEQ:200', 'END'],
      );
      // ... and still materializes a valid one.
      expectVerdict(
        'c6 0c 02 0a 41 07',
        sofab.DecodeStatus.complete,
        events: ['SEQ:200', 'STR:0:A', 'END'],
      );
    });

    test('an out-of-range string_array index is skipped, not validated', () {
      // 2a = header id 5, FIXLEN — index 5 is past the declared count of 5, so
      // it is not a destination and its payload is never inspected.
      expectVerdict(
        'c6 0c 2a 0a 8a 07',
        sofab.DecodeStatus.complete,
        events: ['SEQ:200', 'END'],
      );
    });

    test('struct_array element `v` rejects invalid UTF-8', () {
      // d6 0c SEQ id 202 · 06 SEQ id 0 (element 0) · 0a FIXLEN id 1 (`v`) ·
      // 0a len 1 STRING · 8a · 07 · 07
      expectVerdict(
        'd6 0c 06 0a 0a 8a 07 07',
        sofab.DecodeStatus.invalid,
        events: ['SEQ:202', 'SEQ:0', 'END', 'END'],
      );
      expectVerdict(
        'd6 0c 06 0a 0a 41 07 07',
        sofab.DecodeStatus.complete,
        events: ['SEQ:202', 'SEQ:0', 'STR:1:A', 'END', 'END'],
      );
    });

    // ---- schema `maxlen` still fires at the LENGTH WORD -------------------

    test('over-maxlen declared string that is ALSO truncated → INVALID', () {
      // 56 SEQ id 10 · 12 FIXLEN id 2 · c2 02 fixlen_word length 40 (> maxlen
      // 32), subtype STRING · 41 — one payload byte of forty. §5.2: INVALID
      // dominates INCOMPLETE, and only a check at the length word can see that.
      expectVerdict('56 12 c2 02 41', sofab.DecodeStatus.invalid);
    });

    test('over-maxlen declared string with a full payload → INVALID', () {
      final payload = List<int>.filled(40, 0x41);
      expectBytes(
        Uint8List.fromList([0x56, 0x12, 0xc2, 0x02, ...payload, 0x07]),
        sofab.DecodeStatus.invalid,
      );
    });
  });

  group('F-0038 · the default MessageVisitor stays always-strict', () {
    // A hand-written visitor that does not override `onStringBytes` keeps the
    // pre-fix behaviour exactly: the default hook validates strictly (never
    // U+FFFD) and forwards the decoded value to `onString`.
    test('materialized invalid UTF-8 → INVALID via the default hook', () {
      final v = _Recorder();
      expect(
        sofab.Decoder.decode(_b('56 12 0a 8a 07'), v),
        sofab.DecodeStatus.invalid,
      );
      expect(v.strings, isEmpty);
    });

    test('materialized valid UTF-8 still arrives at onString', () {
      final v = _Recorder();
      expect(
        sofab.Decoder.decode(_b('56 12 0a 41 07'), v),
        sofab.DecodeStatus.complete,
      );
      expect(v.strings, ['2:A']);
    });

    test('shouldRead=false still skips without validating', () {
      final v = _Recorder(skip: {2});
      expect(
        sofab.Decoder.decode(_b('56 12 0a 8a 07'), v),
        sofab.DecodeStatus.complete,
      );
      expect(v.strings, isEmpty);
    });

    test('a rejected string leaves the visitor reusable', () {
      final v = _Recorder();
      expect(
        sofab.Decoder.decode(_b('56 12 0a 8a 07'), v),
        sofab.DecodeStatus.invalid,
      );
      expect(
        sofab.Decoder.decode(_b('56 12 0a 41 07'), v),
        sofab.DecodeStatus.complete,
      );
      expect(v.strings, ['2:A']);
    });
  });

  group('F-0038 · onStringBytes hands over the raw wire bytes', () {
    test('an override sees the un-validated payload verbatim', () {
      final v = _RawGrabber();
      expect(
        sofab.Decoder.decode(_b('56 12 12 ff fe 07'), v),
        sofab.DecodeStatus.complete,
      );
      expect(v.seen, ['2:ff fe']);
    });

    test('the same bytes arrive through the streaming decoder', () {
      final bytes = _b('56 12 12 ff fe 07');
      for (var split = 0; split <= bytes.length; split++) {
        final v = _RawGrabber();
        final d = sofab.Decoder(v);
        d.feed(bytes.sublist(0, split));
        final st = d.feed(bytes.sublist(split));
        expect(st, sofab.DecodeStatus.complete, reason: 'split $split');
        expect(v.seen, ['2:ff fe'], reason: 'split $split');
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Assertions: one-shot, then every chunk split, then byte-at-a-time.
// ---------------------------------------------------------------------------

void expectVerdict(
  String hex,
  sofab.DecodeStatus want, {
  List<String>? events,
}) => expectBytes(_b(hex), want, events: events);

void expectBytes(
  Uint8List bytes,
  sofab.DecodeStatus want, {
  List<String>? events,
}) {
  // One-shot (the contiguous decoder).
  final oneShot = _Sink();
  final st = _verdict(sofab.Decoder.decode(bytes, _Probe(oneShot)), oneShot);
  expect(st, want, reason: 'one-shot ${_hex(bytes)}');
  if (events != null) {
    expect(oneShot.events, events, reason: 'one-shot events ${_hex(bytes)}');
  }

  // Every two-way split, plus byte-at-a-time: §6.4 makes a chunk boundary
  // verdict-neutral, so none of these may differ from the one-shot result.
  for (var split = 0; split <= bytes.length; split++) {
    final s = _Sink();
    final d = sofab.Decoder(_Probe(s));
    var last = d.feed(bytes.sublist(0, split));
    last = d.feed(bytes.sublist(split));
    expect(_verdict(last, s), want, reason: 'split $split of ${_hex(bytes)}');
    if (events != null) {
      expect(s.events, events, reason: 'split $split events ${_hex(bytes)}');
    }
  }

  final s = _Sink();
  final d = sofab.Decoder(_Probe(s));
  var last = sofab.DecodeStatus.complete;
  for (final b in bytes) {
    last = d.feed(<int>[b]);
  }
  if (bytes.isEmpty) last = d.feed(const <int>[]);
  expect(_verdict(last, s), want, reason: 'byte-at-a-time ${_hex(bytes)}');
  if (events != null) {
    expect(s.events, events, reason: 'byte-at-a-time events ${_hex(bytes)}');
  }
}

/// The verdict a schema-bound consumer reports: its sticky INVALID flag
/// dominates the decoder's own status (§5.2 — INVALID over INCOMPLETE).
sofab.DecodeStatus _verdict(sofab.DecodeStatus st, _Sink s) =>
    s.inv ? sofab.DecodeStatus.invalid : st;

// ---------------------------------------------------------------------------
// A stand-in for generated, schema-bound code over Crucible's `probe` schema.
// The shape that matters: the destination switch comes FIRST, and `utf8Valid`
// runs only inside a matched arm.
// ---------------------------------------------------------------------------

class _Sink {
  bool inv = false;
  final List<String> events = <String>[];
}

/// Root of `probe`: scalars 0-7, `nested` 10, `string_array` 200,
/// `struct_array` 202. No `string` destination sits directly on the root.
class _Probe extends sofab.MessageVisitor {
  _Probe(this.s);
  final _Sink s;

  @override
  void onUnsigned(int id, int value) {
    if (id <= 7) s.events.add('U:$id:$value');
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    // No declared `string` at the root — nothing to materialize, nothing to
    // validate. An unknown id lands here and must fall straight through.
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    switch (id) {
      case 10:
        s.events.add('SEQ:10');
        return _Nested(s);
      case 200:
        s.events.add('SEQ:200');
        return _StringSeq(s);
      case 202:
        s.events.add('SEQ:202');
        return _StructSeq(s);
    }
    return null; // unknown wrapper: skip the whole sub-sequence
  }

  @override
  void onSequenceEnd() => s.events.add('END');
}

/// `nested` (id 10): `str` is id 2, maxlen 32.
class _Nested extends sofab.MessageVisitor {
  _Nested(this.s);
  final _Sink s;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    // The schema bound is checked at the LENGTH WORD, before a payload byte is
    // buffered, so INVALID dominates a truncated payload (§5.2 / §7.1).
    if (id == 2 && subtype == sofab.FixlenType.string && length > 32) {
      s.inv = true;
    }
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    switch (id) {
      case 2:
        if (!sofab.utf8Valid(bytes)) {
          s.inv = true;
          return;
        }
        s.events.add('STR:2:${utf8.decode(bytes)}');
        return;
    }
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => null;

  @override
  void onSequenceEnd() => s.events.add('END');
}

/// `string_array` (id 200): element id = index, count 5, maxlen 64.
class _StringSeq extends sofab.MessageVisitor {
  _StringSeq(this.s);
  final _Sink s;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (id < 5 && subtype == sofab.FixlenType.string && length > 64) {
      s.inv = true;
    }
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (id >= 5) return; // past the declared count: not a destination
    if (!sofab.utf8Valid(bytes)) {
      s.inv = true;
      return;
    }
    s.events.add('STR:$id:${utf8.decode(bytes)}');
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => null;

  @override
  void onSequenceEnd() => s.events.add('END');
}

/// `struct_array` (id 202): each element is itself a sequence. A `string`
/// arriving at an element slot is the §7.3 mistyped case — no destination.
class _StructSeq extends sofab.MessageVisitor {
  _StructSeq(this.s);
  final _Sink s;

  @override
  void onStringBytes(int id, Uint8List bytes) {
    // Element slots declare a struct, never a string: fall through untouched.
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    if (id >= 5) return null;
    s.events.add('SEQ:$id');
    return _StructElem(s);
  }

  @override
  void onSequenceEnd() => s.events.add('END');
}

/// A `struct_array` element: `k` is id 0 (u32), `v` is id 1 (string, maxlen 16).
class _StructElem extends sofab.MessageVisitor {
  _StructElem(this.s);
  final _Sink s;

  @override
  void onUnsigned(int id, int value) {
    if (id == 0) s.events.add('U:0:$value');
  }

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (id == 1 && subtype == sofab.FixlenType.string && length > 16) {
      s.inv = true;
    }
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    switch (id) {
      case 1:
        if (!sofab.utf8Valid(bytes)) {
          s.inv = true;
          return;
        }
        s.events.add('STR:1:${utf8.decode(bytes)}');
        return;
    }
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => null;

  @override
  void onSequenceEnd() => s.events.add('END');
}

// ---------------------------------------------------------------------------
// Plain visitors: the default (un-overridden) string path, and a raw-byte tap.
// ---------------------------------------------------------------------------

class _Recorder extends sofab.MessageVisitor {
  _Recorder({this.skip = const <int>{}});
  final Set<int> skip;
  final List<String> strings = <String>[];

  @override
  bool shouldRead(int id, int type) => !skip.contains(id);

  @override
  void onString(int id, String value) => strings.add('$id:$value');
}

class _RawGrabber extends sofab.MessageVisitor {
  final List<String> seen = <String>[];

  @override
  void onStringBytes(int id, Uint8List bytes) => seen.add('$id:${_hex(bytes)}');
}

// ---------------------------------------------------------------------------
// Small helpers.
// ---------------------------------------------------------------------------

/// Parses a space-separated hex byte string (the form the finding quotes).
Uint8List _b(String hex) {
  final tokens = hex.split(' ').where((t) => t.isNotEmpty).toList();
  return Uint8List.fromList(
    tokens.map((t) => int.parse(t, radix: 16)).toList(),
  );
}

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

void _writeVarint(List<int> out, int value) {
  var v = value;
  while (true) {
    final b = v & 0x7f;
    v >>>= 7;
    if (v == 0) {
      out.add(b);
      return;
    }
    out.add(b | 0x80);
  }
}
