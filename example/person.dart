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
  void encodeInto(sofab.Encoder enc) {
    enc.writeString(_idName, name);
    enc.writeUnsigned(_idAge, age);
    // array<string> lowers to a wrapper sequence: element id = array index
    // (MESSAGE_SPEC §5.1).
    enc.beginSequence(_idTags);
    for (var i = 0; i < tags.length; i++) {
      enc.writeString(i, tags[i]);
    }
    enc.endSequence();
  }

  /// One-shot convenience (the 90 % case).
  Uint8List serialize() => sofab.Encoder.encodeToBytes(encodeInto);

  /// Streaming OUT: drive an output sink with a buffer smaller than the object.
  void serializeTo(sofab.FlushCallback sink, {int bufferSize = 64}) {
    final enc = sofab.Encoder(sink, bufferSize: bufferSize);
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
    // Element id == array index (MESSAGE_SPEC §5.1). Grow to fit; absent
    // (default "") elements would leave gaps — filled here for completeness.
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
  print('OK — one-shot and streaming produce identical bytes and objects.');
}

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
