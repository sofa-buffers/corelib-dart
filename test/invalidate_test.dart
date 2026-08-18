import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

/// [sofab.MessageVisitor.invalidate] — the consumer's channel for a verdict the
/// wire layer cannot reach on its own.
///
/// A schema bound (an index past the declared capacity, a string past its
/// `maxlen`, a value outside its declared width) is INVALID under MESSAGE_SPEC
/// §7.1 and knowable only to the consumer. Callbacks return `void`, so before
/// this a consumer carried a flag of its own and converted it after the decode
/// returned. That produced the right verdict — and kept parsing and delivering
/// everything behind the violation, which is what this channel stops
/// (corelib-dart#64).
///
/// Every case runs both engines: the one-shot contiguous walk and the streaming
/// state machine, the latter at several chunk sizes, because CORELIB_PLAN §6.4
/// forbids a chunk boundary from changing an outcome.
void main() {
  // A message with a good field, then the one that trips the consumer, then
  // another good field BEHIND it:
  //   00 07     id 0, unsigned = 7
  //   08 63     id 1, unsigned = 99   <- the visitor rejects this one
  //   10 2a     id 2, unsigned = 42   <- must never be delivered
  final bytes = Uint8List.fromList([0x00, 0x07, 0x08, 0x63, 0x10, 0x2a]);

  const chunkings = [1, 2, 3, 5, 32];

  test('one-shot: reports invalid and delivers nothing behind the rejection',
      () {
    final v = _Rejecting(rejectId: 1);
    expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.invalid);
    expect(v.seen, [0]); // id 2 never arrived
  });

  for (final size in chunkings) {
    test('streaming at $size-byte chunks: same verdict, same deliveries', () {
      final v = _Rejecting(rejectId: 1);
      final dec = sofab.Decoder(v);
      var last = sofab.DecodeStatus.complete;
      for (var i = 0; i < bytes.length; i += size) {
        last = dec.feed(
          Uint8List.sublistView(bytes, i, (i + size).clamp(0, bytes.length)),
        );
      }
      expect(last, sofab.DecodeStatus.invalid);
      expect(v.seen, [0]);
    });
  }

  test('the verdict is terminal: further feeds neither decode nor recover', () {
    final v = _Rejecting(rejectId: 1);
    final dec = sofab.Decoder(v);
    expect(dec.feed(bytes), sofab.DecodeStatus.invalid);
    // A perfectly good continuation must not resurrect the decode (§5.2).
    expect(dec.feed(Uint8List.fromList([0x18, 0x01])),
        sofab.DecodeStatus.invalid);
    expect(v.seen, [0]);
  });

  test('the control decodes clean, so the reject is a verdict and not a blanket',
      () {
    final v = _Rejecting(rejectId: 99);
    expect(sofab.Decoder.decode(bytes, v), sofab.DecodeStatus.complete);
    expect(v.seen, [0, 1, 2]);
  });

  test('works from inside a nested scope, and stops the outer one too', () {
    // 0e        id 1, sequence start
    // 00 63     id 0, unsigned = 99   <- the CHILD rejects
    // 07        sequence end
    // 10 2a     id 2, unsigned = 42   <- must never be delivered
    final nested =
        Uint8List.fromList([0x0e, 0x00, 0x63, 0x07, 0x10, 0x2a]);
    final root = _Nesting();
    expect(sofab.Decoder.decode(nested, root), sofab.DecodeStatus.invalid);
    expect(root.seen, isEmpty);
    expect(root.child.seen, isEmpty);

    for (final size in chunkings) {
      final r = _Nesting();
      final dec = sofab.Decoder(r);
      var last = sofab.DecodeStatus.complete;
      for (var i = 0; i < nested.length; i += size) {
        last = dec.feed(
          Uint8List.sublistView(nested, i, (i + size).clamp(0, nested.length)),
        );
      }
      expect(last, sofab.DecodeStatus.invalid, reason: 'chunk size $size');
      expect(r.seen, isEmpty, reason: 'chunk size $size');
    }
  });
}

/// Rejects one id the way a generated consumer rejects a schema-bound
/// violation, and records every id it was actually handed.
class _Rejecting extends sofab.MessageVisitor {
  _Rejecting({required this.rejectId});

  final int rejectId;
  final List<int> seen = <int>[];

  @override
  void onUnsigned(int id, int value) {
    if (id == rejectId) {
      invalidate();
      return; // unreachable, and the shape generated code emits
    }
    seen.add(id);
  }
}

class _Nesting extends sofab.MessageVisitor {
  final List<int> seen = <int>[];
  final _Rejecting child = _Rejecting(rejectId: 0);

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => child;

  @override
  void onUnsigned(int id, int value) => seen.add(id);
}
