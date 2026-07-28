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

  group('every header-writing entry point commits the pending run', () {
    // The commit hook sits in the single `_writeHeader` choke point, but each
    // writer is a separate call site into it — including the two inside
    // `writeString` (the ASCII fast path and the strict-transcode path). A
    // writer that reached the wire without committing would silently drop its
    // enclosing frames while their `end` markers stayed behind, i.e. corrupt
    // bytes rather than a visible failure, so drive ALL of them.
    final writers = <String, void Function(sofab.Encoder)>{
      'writeUnsigned': (e) => e.writeUnsigned(0, 42),
      'writeSigned': (e) => e.writeSigned(0, -42),
      'writeBool': (e) => e.writeBool(0, true),
      'writeFp32': (e) => e.writeFp32(0, 1.5),
      'writeFp32Bits': (e) => e.writeFp32Bits(0, 0x7F800001),
      'writeFp64': (e) => e.writeFp64(0, 2.5),
      'writeString (ASCII fast path)': (e) => e.writeString(0, 'ada'),
      'writeString (strict transcode)': (e) => e.writeString(0, 'adaé€'),
      'writeBlob': (e) => e.writeBlob(0, Uint8List.fromList([1, 2, 3])),
      'writeUnsignedArray': (e) => e.writeUnsignedArray(0, const [1, 2]),
      'writeSignedArray': (e) => e.writeSignedArray(0, const [-1, 2]),
      'writeFp32Array': (e) => e.writeFp32Array(0, const [1.0, 2.0]),
      'writeFp64Array': (e) => e.writeFp64Array(0, const [1.0, 2.0]),
    };

    writers.forEach((name, write) {
      test(name, () {
        final bare = enc(write); // the same field with no enclosing frame
        // Two levels deep, so this also proves the WHOLE run is committed,
        // outermost header first — not merely the innermost one.
        final framed = enc((e) {
          e.beginSequenceLazy(1);
          e.beginSequenceLazy(2);
          write(e);
          e.endSequence();
          e.endSequence();
        });
        expect(framed, equals(<int>[0x0E, 0x16] + bare + <int>[0x07, 0x07]));
        // ...and both frames are really on the wire for a decoder.
        final rec = RecordingVisitor();
        expect(sofab.Decoder.decode(framed, rec), sofab.DecodeStatus.complete);
        expect(rec.events.take(2), equals(['SEQ:1', 'SEQ:2']));
      });
    });
  });

  test('a run committed across flush boundaries equals the one-shot bytes', () {
    // What this proves: driving the same sequence of calls through a 3-byte
    // output buffer — so the flush callback fires several times *inside* the
    // committed frames, including between a header and the field it encloses —
    // yields byte-identical output to the one-shot encode (CORELIB_PLAN §5.1,
    // §6).
    //
    // What it deliberately does NOT claim is that a flush lands while a header
    // is still held back: that is UNREACHABLE BY CONSTRUCTION. A held-back
    // header occupies no buffer space (the pending ids are encoder state, not
    // buffer content), and the buffer only fills through a write — which runs
    // the commit before its first byte reaches the buffer. So a pending run can
    // never straddle a flush, and no buffer size can make it.
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

  test('the hold-back is unbounded — 40 deep, all contentless, zero bytes', () {
    // There is NO hold-back window. This port can allocate, so it must hold
    // back to the full MAX_DEPTH and be canonical at every depth (CORELIB_PLAN
    // §6, "How deep the hold-back reaches"); only a heap-free profile may bound
    // the run and frame eagerly past the bound. 40 is deeper than the fixed
    // 32-entry window this encoder used to have — exactly the depth at which
    // the old eager fallback emitted 40 empty frames instead of nothing.
    expect(
      enc((e) {
        for (var i = 0; i < 40; i++) {
          e.beginSequenceLazy(1);
        }
        for (var i = 0; i < 40; i++) {
          e.endSequence();
        }
      }),
      isEmpty,
    );
  });

  test('the hold-back reaches MAX_DEPTH', () {
    // The ceiling itself: 255 nested contentless sequences still vanish, and a
    // single leaf at the bottom brings all 255 headers back in wire order.
    expect(
      enc((e) {
        for (var i = 0; i < sofab.maxDepth; i++) {
          e.beginSequenceLazy(1);
        }
        for (var i = 0; i < sofab.maxDepth; i++) {
          e.endSequence();
        }
      }),
      isEmpty,
    );

    final withLeaf = enc((e) {
      for (var i = 0; i < sofab.maxDepth; i++) {
        e.beginSequenceLazy(1);
      }
      e.writeUnsigned(0, 42);
      for (var i = 0; i < sofab.maxDepth; i++) {
        e.endSequence();
      }
    });
    expect(
      withLeaf,
      equals(
        List<int>.filled(sofab.maxDepth, 0x0E) +
            <int>[0x00, 0x2A] +
            List<int>.filled(sofab.maxDepth, 0x07),
      ),
    );
    // ...and it decodes: the committed run is well-formed at full depth.
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(withLeaf, rec), sofab.DecodeStatus.complete);
  });

  test('a deep run drops only the empty sequences, at any depth', () {
    // Interleaving past the old window: 40 nested frames, a leaf written at the
    // bottom of the 30th, and empty siblings on either side. Only the empty
    // ones vanish; the ancestors of the leaf are all framed.
    final bytes = enc((e) {
      for (var i = 0; i < 40; i++) {
        e.beginSequenceLazy(1);
        if (i == 29) {
          e.beginSequenceLazy(2); // empty sibling before the content
          e.endSequence();
          e.writeUnsigned(0, 7);
        }
      }
      for (var i = 0; i < 40; i++) {
        e.endSequence();
      }
    });
    // 30 headers (ids 1..1) are committed by the leaf; the 10 deeper ones and
    // the empty sibling never reach the wire.
    expect(
      bytes,
      equals(
        List<int>.filled(30, 0x0E) +
            <int>[0x00, 0x07] +
            List<int>.filled(30, 0x07),
      ),
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
