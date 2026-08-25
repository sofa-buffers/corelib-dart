import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Truncation tests (CORELIB_PLAN §5.2, §7.2 item 6): a message cut short
/// mid-field must return INCOMPLETE — not INVALID and not COMPLETE — and feeding
/// the missing bytes then completes it. There is no finalize step.
void main() {
  sofab.DecodeStatus decode(String hex) =>
      sofab.Decoder.decode(hexToBytes(hex), RecordingVisitor());

  /// The same decode with the receiver's array cap wound out to the format
  /// ceiling, so an ARRAY_MAX count is *admitted* and the outcome is decided by
  /// the bytes rather than by policy (CORELIB_PLAN §6.2.1). Without this the
  /// cases below would be measuring [sofab.defaultMaxDynArrayCount].
  sofab.DecodeStatus decodeUncapped(String hex) => sofab.Decoder.decode(
    hexToBytes(hex),
    RecordingVisitor(),
    limits: const sofab.DecoderLimits(maxArrayCount: sofab.arrayMax),
  );

  test('empty input is COMPLETE (valid empty message)', () {
    expect(decode(''), sofab.DecodeStatus.complete);
  });

  test('lone dangling 0x80 → INCOMPLETE (well-formed varint prefix)', () {
    expect(decode('80'), sofab.DecodeStatus.incomplete);
  });

  test('header present, value varint missing → INCOMPLETE', () {
    expect(
      decode('00'),
      sofab.DecodeStatus.incomplete,
    ); // id0 unsigned, no value
  });

  test('fixlen payload shorter than declared length → INCOMPLETE', () {
    // string id0, declared length 3, only 1 payload byte present.
    expect(decode('021a61'), sofab.DecodeStatus.incomplete);
  });

  test('unclosed sequence → INCOMPLETE', () {
    // seq start id0, one field, no matching end.
    expect(
      decode(
        '06'
        '0001',
      ),
      sofab.DecodeStatus.incomplete,
    );
  });

  test('array with fewer elements than count → INCOMPLETE', () {
    // array-unsigned id0, count 3, only 2 elements.
    expect(
      decode(
        '03'
        '03'
        '01'
        '02',
      ),
      sofab.DecodeStatus.incomplete,
    );
  });

  test('feeding the missing bytes completes an INCOMPLETE stream', () {
    final rec = RecordingVisitor();
    final dec = sofab.Decoder(rec);
    // string id0 length 3 "abc", split across three feeds.
    expect(dec.feed(hexToBytes('021a')), sofab.DecodeStatus.incomplete);
    expect(dec.feed(hexToBytes('6162')), sofab.DecodeStatus.incomplete);
    expect(dec.feed(hexToBytes('63')), sofab.DecodeStatus.complete);
    expect(rec.events, ['STR:0:abc']);
  });

  test('INCOMPLETE is not promoted to an error by a later empty feed', () {
    final dec = sofab.Decoder(RecordingVisitor());
    expect(dec.feed(hexToBytes('80')), sofab.DecodeStatus.incomplete);
    expect(dec.feed(const []), sofab.DecodeStatus.incomplete);
  });

  // On the one-shot surface the whole message is in hand, so a count above the
  // bytes that remain (one byte per element, minimum) already proves the array
  // can never complete. Sizing the result from that count alone turns a 6-byte
  // message into a 17 GB allocation request — §7.2 item 5 says an oversized
  // count is a well-defined outcome, never a crash, and §6.2.1 says the decision
  // comes *before* the allocation it prevents.
  group('an element count larger than the input never sizes the result', () {
    // count = ARRAY_MAX (2^31-1, the largest legal count) with zero elements.
    const maxCount = 'ffffffff07';

    test('unsigned array, count ARRAY_MAX, no elements → INCOMPLETE', () {
      expect(decodeUncapped('03$maxCount'), sofab.DecodeStatus.incomplete);
    });

    test('signed array, count ARRAY_MAX, no elements → INCOMPLETE', () {
      expect(decodeUncapped('0c$maxCount'), sofab.DecodeStatus.incomplete);
    });

    // And with the receiver's own cap in place — which is what an unconfigured
    // decoder carries (§6.2.1: "There is no unset state and no unlimited
    // mode") — the same count never reaches the element loop at all: it is
    // refused at the count word, as a policy rejection distinct from INVALID.
    test('under the default caps the same count is limitExceeded', () {
      expect(decode('03$maxCount'), sofab.DecodeStatus.limitExceeded);
      expect(decode('0c$maxCount'), sofab.DecodeStatus.limitExceeded);
    });

    test('the skipping path decides the same way', () {
      // A skipped field allocates nothing, so no cap is applied to it
      // (§6.2.1) — the outcome is the truncation, whatever the caps are.
      expect(
        sofab.Decoder.decode(
          hexToBytes('03$maxCount'),
          RecordingVisitor(skipIds: const {0}),
        ),
        sofab.DecodeStatus.incomplete,
      );
    });

    test('a decodable prefix is still not delivered', () {
      final rec = RecordingVisitor();
      // Three elements on the wire, ARRAY_MAX declared.
      expect(
        sofab.Decoder.decode(
          hexToBytes('03${maxCount}010203'),
          rec,
          limits: const sofab.DecoderLimits(maxArrayCount: sofab.arrayMax),
        ),
        sofab.DecodeStatus.incomplete,
      );
      expect(rec.events.where((e) => e.startsWith('AU:')), isEmpty);
    });

    test('a length larger than the input never sizes a destination', () {
      // The fixlen twin of the cases above: a `string` announcing FIXLEN_MAX
      // bytes with none present. The one-shot surface knows the buffer cannot
      // back that length, so it never asks the caller for a destination; the
      // streaming surface has the receiver cap for the same job.
      var asked = false;
      final st = sofab.Decoder.decode(
        hexToBytes('02f2ffffff0f'),
        _AskRecorder(() => asked = true),
        limits: const sofab.DecoderLimits(maxStringLen: sofab.fixlenMax),
      );
      expect(st, sofab.DecodeStatus.incomplete);
      expect(asked, isFalse);
    });

    test('a count that the input can satisfy is unaffected', () {
      final rec = RecordingVisitor();
      expect(
        sofab.Decoder.decode(hexToBytes('0303010203'), rec),
        sofab.DecodeStatus.complete,
      );
      expect(rec.events, ['AU:0:1,2,3']);
    });
  });
}

/// Records whether the decoder ever asked for a payload destination.
class _AskRecorder extends sofab.MessageVisitor {
  _AskRecorder(this.onAsk);
  final void Function() onAsk;

  @override
  Uint8List? onBytesDest(int id, int subtype, int total) {
    onAsk();
    return Uint8List(total);
  }
}
