// ignore_for_file: avoid_print
//
// A hand-written illustration of the **generated-object layer** (CORELIB_PLAN
// §6.1). This is what the `generator` would emit from a schema: a plain typed
// object whose API is dead simple — the user thinks in fields and
// (de)serialize, never in varints, ids, or buffers — yet which is built entirely
// on the corelib's streaming primitives and therefore also streams in chunks.
//
// Schema (conceptually):
//   message Person { string name = 0; u32 age = 1; array<string> tags = 2; }

import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

class Person {
  String name = '';
  int age = 0;
  List<String> tags = <String>[];

  static const int _idName = 0;
  static const int _idAge = 1;
  static const int _idTags = 2;

  /// Writes this object's fields through [enc] (the streaming path). The
  /// one-shot [serialize] and the chunked [serializeTo] both funnel through
  /// here, so there is a single encoding.
  ///
  /// **One rule, applied everywhere: emit a field iff its value ≠ its declared
  /// default** (MESSAGE_SPEC §2 — sparse encoding is mandatory and canonical;
  /// there is no dense mode). The schema declares no `default`, so each field's
  /// default is its type's zero value: `''`, `0`, and the empty list. Absence
  /// reconstructs exactly that, which is why omitting is value-preserving.
  void encodeInto(sofab.Encoder enc) {
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

  /// One-shot convenience (the 90 % case).
  Uint8List serialize() => sofab.Encoder.encodeToBytes(encodeInto);

  /// Streaming OUT: drive an output sink with a buffer smaller than the object.
  ///
  /// Note where the allocation lives: **here**, in the generated layer, not in
  /// the corelib. The encoder writes into a buffer this method supplies, like
  /// any other caller — CORELIB_PLAN §5.1, "the generated-object layer
  /// allocates; the corelib does not". `Person` has no schema `MAX_SIZE` bound,
  /// so this is the unbounded shape: a small scratch buffer plus a sink. A
  /// bounded schema would instead allocate `MAX_SIZE` once and use
  /// `sofab.Encoder.overBuffer` with no sink at all.
  void serializeTo(sofab.FlushCallback sink, {int bufferSize = 64}) {
    final enc = sofab.Encoder(sink, buffer: Uint8List(bufferSize));
    encodeInto(enc);
    enc.flush();
  }

  /// One-shot convenience.
  static Person deserialize(Uint8List bytes) {
    final dec = PersonDecoder();
    dec.feed(bytes);
    return dec.value;
  }

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
    _visitor = _PersonVisitor(value);
    _dec = sofab.Decoder(_visitor);
  }

  final Person value = Person();
  late final _PersonVisitor _visitor;
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
  final bytes = ada.serialize();
  final back = Person.deserialize(bytes);
  print('one-shot : $back  (${bytes.length} bytes)');
  assert(back.name == 'Ada' && back.age == 36 && back.tags.length == 2);

  // --- streaming out (tiny buffer) + streaming in (1 byte at a time) ---
  final collected = BytesBuilder(copy: true);
  ada.serializeTo(collected.add, bufferSize: 4);
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
  final empty = Person().serialize();
  print('all-default: ${empty.length} bytes  → ${Person.deserialize(empty)}');
  assert(empty.isEmpty);
  final blank = Person.deserialize(empty);
  assert(blank.name == '' && blank.age == 0 && blank.tags.isEmpty);

  // A default-valued element is omitted too, so it leaves an id gap and a
  // trailing default element collapses: ['x', ''] encodes exactly like ['x'],
  // and round-trips losslessly against a default-initialised destination.
  final gapped = (Person()..tags = ['', 'b', '']).serialize();
  assert(_hex(gapped) == _hex((Person()..tags = ['', 'b']).serialize()));
  assert(Person.deserialize(gapped).tags.join(',') == ',b');
  print('OK — one-shot and streaming produce identical bytes and objects.');
}

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
