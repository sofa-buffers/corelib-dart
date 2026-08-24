// ignore_for_file: avoid_print
//
// A hand-written illustration of the **generated-object layer** (CORELIB_PLAN
// §6.1). This is what the `generator` would emit from a schema: a plain typed
// object whose API is dead simple — the user thinks in fields and
// encode/decode, never in varints, ids, or buffers — yet which is built entirely
// on the corelib's streaming primitives and therefore also streams in chunks.
//
// Its surface is the closed name set of §6.1.1, cased Dart's way and nothing
// besides: `encode()` / `decode(bytes)` are the one-shot convenience pair,
// `serialize(ostream)` / `deserialize(istream)` the streaming pair underneath
// it, and `decoder()` hands back the chunk reader. A port MUST NOT add a second
// name for either pair — no `serializeTo` beside `serialize`, no `fromBytes`
// beside `decode` — so a user who learned the surface in one language already
// knows it here. Everything the methods call into (`writeString`, `feed`,
// `beginSequenceLazy`, …) is corelib API (§6) and keeps its own names.
//
// Schema (conceptually):
//   message Person { string name = 0; u32 age = 1; array<string> tags = 2; }

import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;

class Person {
  String name = '';
  int age = 0;
  List<String> tags = <String>[];

  static const int _idName = 0;
  static const int _idAge = 1;
  static const int _idTags = 2;

  /// Streaming OUT (§6.1.1 `serialize`): writes this object's fields through
  /// [enc], whose buffer may be far smaller than the message — it drains
  /// through the flush callback as it fills. The one-shot [encode] funnels
  /// through here too, so there is a single encoding and no second name for it.
  ///
  /// **One rule, applied everywhere: emit a field iff its value ≠ its declared
  /// default** (MESSAGE_SPEC §2 — sparse encoding is mandatory and canonical;
  /// there is no dense mode). The schema declares no `default`, so each field's
  /// default is its type's zero value: `''`, `0`, and the empty list. Absence
  /// reconstructs exactly that, which is why omitting is value-preserving.
  void serialize(sofab.Encoder enc) {
    // Leaf fields: the plain ≠-default test.
    if (name != '') enc.writeString(_idName, name);
    if (age != 0) enc.writeUnsigned(_idAge, age);
    // array<string> lowers to a wrapper sequence: element id = array index
    // (MESSAGE_SPEC §5.1). A sequence-typed field is no exception to the rule —
    // it is compared per child, recursively, and "not one child was written" is
    // exactly "equals the default". `beginSequenceLazy` holds the header back
    // so the encoder gets that test for free, and `endSequence` lets a `tags`
    // that stayed empty vanish entirely rather than emit an empty frame.
    enc.beginSequenceLazy(_idTags);
    for (var i = 0; i < tags.length; i++) {
      // The same rule again, one level down: a `string` element is a leaf
      // field, so a default-valued one is omitted — the one place an array
      // leaves an id gap on the wire (MESSAGE_SPEC §2, §5.1). Were these
      // elements *sequences*, this would be the one exception: each would close
      // with `endSequenceKeep`, because element presence is what carries the
      // array's length (highest present id + 1) and dropping an all-default
      // element would change that length, not just the bytes.
      if (tags[i] != '') enc.writeString(i, tags[i]);
    }
    enc.endSequence();
  }

  /// One-shot convenience (the 90 % case) — §6.1.1 `encode`.
  ///
  /// Note where the allocation lives: in the generated layer, not in the
  /// corelib. `encodeToBytes` allocates a scratch buffer and drives an encoder
  /// over it like any other caller — CORELIB_PLAN §5.1, "the generated-object
  /// layer allocates; the corelib does not". `Person` has no schema `MAX_SIZE`
  /// bound, so this is the unbounded shape: scratch buffer plus a sink that
  /// appends into the growing result. A bounded schema would instead allocate
  /// `MAX_SIZE` once and use `sofab.Encoder.overBuffer` with no sink at all.
  ///
  /// There is no second, chunked entry point beside it: a caller who wants to
  /// stream into a sink of their own builds the encoder and calls [serialize],
  /// which is the §5.1 pattern anyway — see `main` below.
  Uint8List encode() => sofab.Encoder.encodeToBytes(serialize);

  /// One-shot convenience — §6.1.1 `decode`.
  static Person decode(Uint8List bytes) {
    final dec = PersonDecoder();
    dec.feed(bytes);
    return dec.value;
  }

  /// Streaming IN (§6.1.1 `deserialize`): the per-field hook the corelib's
  /// decoder calls, bound to this instance. Dart spells that hook as a visitor
  /// object (§5.2), so this hands one over: give it to a `sofab.Decoder` and
  /// every field the decoder reads lands in a field of `this`.
  ///
  /// [decoder] is the packaged form of the same thing for the common case.
  sofab.MessageVisitor deserialize() => _PersonVisitor(this);

  /// Streaming IN: a generated reader bound to the corelib decoder.
  static PersonDecoder decoder() => PersonDecoder();

  @override
  String toString() => 'Person(name: $name, age: $age, tags: $tags)';
}

/// The generated streaming decoder: feed it arbitrarily small chunks; the
/// object assembles incrementally across chunk boundaries. `feed` returns the
/// corelib's status verbatim — no finalize step (MESSAGE_SPEC §7).
class PersonDecoder {
  PersonDecoder() {
    _dec = sofab.Decoder(value.deserialize());
  }

  final Person value = Person();
  late final sofab.Decoder _dec;

  sofab.DecodeStatus feed(List<int> chunk) => _dec.feed(chunk);
}

class _PersonVisitor extends sofab.MessageVisitor {
  _PersonVisitor(this.p);
  final Person p;

  @override
  void onString(int id, String value) {
    if (id == Person._idName) p.name = value;
  }

  @override
  void onUnsigned(int id, int value) {
    if (id == Person._idAge) p.age = value;
  }

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    if (id == Person._idTags) return _TagsVisitor(p.tags);
    return null; // skip anything unknown
  }
}

class _TagsVisitor extends sofab.MessageVisitor {
  _TagsVisitor(this.tags);
  final List<String> tags;

  @override
  void onString(int id, String value) {
    // Element id == array index (MESSAGE_SPEC §5.1). The encoder omits an
    // element equal to its default, so ids arrive with gaps; the decode side of
    // the same rule is to restore each missing `dest[id]` from that default.
    while (tags.length <= id) {
      tags.add('');
    }
    tags[id] = value;
  }
}

void main() {
  final ada = Person()
    ..name = 'Ada'
    ..age = 36
    ..tags = ['pioneer', 'mathematician'];

  // --- one-shot ---
  final bytes = ada.encode();
  final back = Person.decode(bytes);
  print('one-shot : $back  (${bytes.length} bytes)');
  assert(back.name == 'Ada' && back.age == 36 && back.tags.length == 2);

  // --- streaming out (tiny buffer) + streaming in (1 byte at a time) ---
  // No chunked convenience method exists, and none is wanted: build the encoder
  // over the buffer *you* own — four bytes here, far less than the message —
  // give it your sink, and call the same `serialize` the one-shot path uses.
  final collected = BytesBuilder(copy: true);
  final enc = sofab.Encoder(collected.add, buffer: Uint8List(4));
  ada.serialize(enc);
  enc.flush();
  final streamed = collected.toBytes();
  assert(_hex(streamed) == _hex(bytes)); // identical to one-shot

  final dec = Person.decoder();
  sofab.DecodeStatus status = sofab.DecodeStatus.incomplete;
  for (final b in streamed) {
    status = dec.feed([b]);
  }
  print('streamed : ${dec.value}  (status: ${status.name})');
  assert(status == sofab.DecodeStatus.complete);
  assert(dec.value.tags[1] == 'mathematician');

  // --- the sparse rule, taken to its conclusion ---
  // Every field at its default → every field omitted → the empty byte string
  // (MESSAGE_SPEC §2). The `tags` sequence is omitted with the rest: its header
  // was never committed, so not even an empty frame reaches the wire.
  final empty = Person().encode();
  print('all-default: ${empty.length} bytes  → ${Person.decode(empty)}');
  assert(empty.isEmpty);
  final blank = Person.decode(empty);
  assert(blank.name == '' && blank.age == 0 && blank.tags.isEmpty);

  // A default-valued element is omitted too, so it leaves an id gap and a
  // trailing default element collapses: ['x', ''] encodes exactly like ['x'],
  // and round-trips losslessly against a default-initialised destination.
  final gapped = (Person()..tags = ['', 'b', '']).encode();
  assert(_hex(gapped) == _hex((Person()..tags = ['', 'b']).encode()));
  assert(Person.decode(gapped).tags.join(',') == ',b');
  print('OK — one-shot and streaming produce identical bytes and objects.');
}

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
