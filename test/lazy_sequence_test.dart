import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Lazy sequence framing (MESSAGE_SPEC §2, CORELIB_PLAN §6).
///
/// A sequence-typed **field** whose value equals its declared default is
/// omitted rather than emitted as an empty `begin`/`end` frame. Because the
/// message layer already omits every child equal to its default, "not one child
/// was written" *is* "the object equals its declared default" — evaluated per
/// child field, recursively, for free. The header is therefore held back until
/// content proves the sequence non-default.
///
/// A wrapper-array **element** keeps its frame even when all-default, because
/// element presence is what carries a dynamic array's length (highest present
/// id + 1, §5.1); that is what [sofab.Encoder.endSequenceKeep] is for.
void main() {
  /// One-shot encode helper: a buffer far larger than any message here.
  Uint8List enc(void Function(sofab.Encoder e) build) =>
      sofab.Encoder.encodeToBytes(build);

  test('a contentless lazy sequence emits nothing', () {
    // An all-default sequence carries no information, so the field is omitted —
    // where the eager API would have written the two-byte empty frame 0E 07.
    expect(
      enc((e) {
        e.beginSequenceLazy(1);
        e.endSequence();
      }),
      isEmpty,
    );
  });

  test('endSequenceKeep frames a contentless sequence', () {
    // The array-element and explicit-empty cases of §2 / §5.1.
    expect(
      enc((e) {
        e.beginSequenceLazy(1);
        e.endSequenceKeep();
      }),
      equals([0x0E, 0x07]),
    );
  });

  test('endSequenceKeep commits the enclosing run', () {
    // Forcing a frame forces its ancestors too: the outer sequence got content
    // (the inner frame), so it is framed as well.
    expect(
      enc((e) {
        e.beginSequenceLazy(1);
        e.beginSequenceLazy(2);
        e.endSequenceKeep();
        e.endSequence();
      }),
      equals([0x0E, 0x16, 0x07, 0x07]),
    );
  });

  test('endSequenceKeep matches endSequence once content exists', () {
    // With content it makes no difference — the headers are already out.
    final withKeep = enc((e) {
      e.beginSequenceLazy(1);
      e.writeUnsigned(0, 42);
      e.endSequenceKeep();
    });
    final withEnd = enc((e) {
      e.beginSequenceLazy(1);
      e.writeUnsigned(0, 42);
      e.endSequence();
    });
    expect(withKeep, equals([0x0E, 0x00, 0x2A, 0x07]));
    expect(withKeep, equals(withEnd));
  });

  test('first content commits the whole held-back run', () {
    // One child field commits the whole run, outermost header first, so a
    // non-default leaf deep inside brings every enclosing frame back in wire
    // order.
    expect(
      enc((e) {
        e.beginSequenceLazy(1);
        e.beginSequenceLazy(2);
        e.writeUnsigned(0, 42);
        e.endSequence();
        e.endSequence();
      }),
      equals([0x0E, 0x16, 0x00, 0x2A, 0x07, 0x07]),
    );
  });

  test('only the empty inner sequence is dropped', () {
    // The outer one has content (the leaf) and is framed. This is the
    // interleaving that a naive "drop the whole run" would get wrong.
    expect(
      enc((e) {
        e.beginSequenceLazy(1);
        e.beginSequenceLazy(2);
        e.endSequence();
        e.writeUnsigned(0, 42);
        e.endSequence();
      }),
      equals([0x0E, 0x00, 0x2A, 0x07]),
    );
  });

  test('a lazy sequence after content is independent', () {
    // A dropped sequence between two siblings leaves their order intact.
    expect(
      enc((e) {
        e.writeUnsigned(0, 1);
        e.beginSequenceLazy(1);
        e.endSequence();
        e.writeUnsigned(2, 3);
      }),
      equals([0x00, 0x01, 0x10, 0x03]),
    );
  });

  test('lazy framing is output-buffer-size independent', () {
    // Held-back ids are ENCODER STATE, not buffer content, so a flush can never
    // split a pending run: a 3-byte buffer produces exactly the one-shot bytes
    // (CORELIB_PLAN §5.1, §6).
    void build(sofab.Encoder e) {
      e.beginSequenceLazy(1);
      e.beginSequenceLazy(2);
      e.endSequence();
      e.writeUnsigned(0, 42);
      e.beginSequenceLazy(3);
      e.writeString(1, 'streaming-past-the-buffer');
      e.endSequenceKeep();
      e.endSequence();
    }

    final out = BytesBuilder(copy: true);
    final e = sofab.Encoder(out.add, bufferSize: 3);
    build(e);
    e.flush();

    expect(bytesToHex(out.toBytes()), equals(bytesToHex(enc(build))));
    // ...and it is the shape we expect: the empty inner frame is gone, the
    // forced one survives.
    expect(out.toBytes().sublist(0, 4), equals([0x0E, 0x00, 0x2A, 0x1E]));
  });

  test('a run deeper than the hold-back window is framed eagerly', () {
    // Past lazySeqDepth the encoder commits the whole run and writes the header
    // immediately. That keeps "pending is a contiguous suffix of the open
    // sequences" true, so endSequence still closes THIS sequence rather than
    // popping an ancestor — the frames are merely non-canonical (kept even
    // though every one of them is empty).
    final n = sofab.lazySeqDepth + 1;
    final bytes = enc((e) {
      for (var i = 0; i < n; i++) {
        e.beginSequenceLazy(1);
      }
      for (var i = 0; i < n; i++) {
        e.endSequence();
      }
    });
    expect(
      bytes,
      equals(
        List<int>.filled(n, 0x0E) + List<int>.filled(n, 0x07),
        // n begins, then n ends — nothing dropped, nothing mispaired.
      ),
    );
    // Exactly at the window everything still vanishes.
    expect(
      enc((e) {
        for (var i = 0; i < sofab.lazySeqDepth; i++) {
          e.beginSequenceLazy(1);
        }
        for (var i = 0; i < sofab.lazySeqDepth; i++) {
          e.endSequence();
        }
      }),
      isEmpty,
    );
  });

  test('beginSequenceLazy rejects an out-of-range id', () {
    expect(
      () => enc((e) => e.beginSequenceLazy(sofab.idMax + 1)),
      throwsA(
        isA<sofab.SofabException>().having(
          (e) => e.code,
          'code',
          sofab.SofabError.invalidArgument,
        ),
      ),
    );
    expect(
      () => enc((e) => e.beginSequenceLazy(-1)),
      throwsA(isA<sofab.SofabException>()),
    );
  });

  test('reset clears held-back sequence headers', () {
    final out = BytesBuilder(copy: true);
    final e = sofab.Encoder(out.add, bufferSize: 64);
    e.beginSequenceLazy(1); // held back, then abandoned
    e.reset();
    e.writeUnsigned(0, 1);
    e.flush();
    expect(out.toBytes(), equals([0x00, 0x01]));
  });

  test('a dropped frame and a kept one decode to the same value', () {
    // The direction-of-safety argument: an empty frame is a NON-CANONICAL
    // encoding of the omitted field, so a decoder normalizes it away
    // (MESSAGE_SPEC §2). Emitting one where `endSequence` would do costs two
    // bytes; the reverse would change an array's length.
    final dropped = enc((e) {
      e.writeUnsigned(0, 7);
      e.beginSequenceLazy(1);
      e.endSequence();
    });
    final kept = enc((e) {
      e.writeUnsigned(0, 7);
      e.beginSequenceLazy(1);
      e.endSequenceKeep();
    });
    expect(bytesToHex(dropped), equals('0007'));
    expect(bytesToHex(kept), equals('00070e07'));

    final a = RecordingVisitor();
    final b = RecordingVisitor();
    expect(sofab.Decoder.decode(dropped, a), sofab.DecodeStatus.complete);
    expect(sofab.Decoder.decode(kept, b), sofab.DecodeStatus.complete);
    expect(a.events, equals(['U:0:7']));
    // The kept frame is visible on the wire but carries no child.
    expect(b.events, equals(['U:0:7', 'SEQ:1', 'END']));
  });
}
