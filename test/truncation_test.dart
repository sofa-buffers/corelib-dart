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

  /// The same decode. There is no cap to wind out any more (CORELIB_PLAN
  /// §6.2.1: the decoder holds none), so an ARRAY_MAX count is admitted and the
  /// outcome is decided by the bytes — which is what these cases are about.
  /// The one-shot walker never sizes a destination from a count the input
  /// cannot back, so an impossible count costs nothing here.
  sofab.DecodeStatus decodeUncapped(String hex) =>
      sofab.Decoder.decode(hexToBytes(hex), RecordingVisitor());

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

  // §7.2 item 6: "Cover a `fixlen_word` cut after its first byte with that byte
  // carrying a reserved subtype (0x4–0x7): the subtype is already settled by
  // the low 3 bits, so an implementation that evaluates it early answers
  // INVALID where §4.1.1 requires INCOMPLETE. Nothing else in this list
  // exercises the no-partial-evaluation rule."
  group('no part of an incomplete varint is evaluated (§4.1.1)', () {
    for (final sub in const [0x4, 0x5, 0x6, 0x7]) {
      test('a fixlen_word cut after a first byte carrying subtype $sub', () {
        // header id 0 fixlen, then one continuation byte whose low 3 bits are
        // the reserved subtype. The word is unfinished, so nothing about it is
        // settled — INCOMPLETE, not INVALID.
        final hex = '02${(0x80 | sub).toRadixString(16).padLeft(2, '0')}';
        expect(decode(hex), sofab.DecodeStatus.incomplete);

        final dec = sofab.Decoder(RecordingVisitor());
        var st = sofab.DecodeStatus.complete;
        for (final b in hexToBytes(hex)) {
          st = dec.feed([b]);
        }
        expect(st, sofab.DecodeStatus.incomplete);
      });
    }

    test('and the completed word with a reserved subtype is INVALID', () {
      // The control: once the varint terminates, the subtype decides.
      expect(decode('0204'), sofab.DecodeStatus.invalid); // len 0, subtype 4
      expect(decode('028400'), sofab.DecodeStatus.invalid); // the same, in two
    });

    test('an array fixlen_word cut the same way is INCOMPLETE too', () {
      // array id 0 fixlen, count 1, then a first word byte carrying subtype 4.
      expect(decode('050184'), sofab.DecodeStatus.incomplete);
      expect(decode('050104'), sofab.DecodeStatus.invalid);
    });

    test('a field header cut mid-varint settles no wire type', () {
      // The low 3 bits say "sequence end", which would balance nothing — but
      // the header is unfinished, so it says nothing at all yet.
      expect(decode('87'), sofab.DecodeStatus.incomplete);
    });
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

    // And with a receiver cap in place — which lives in the consumer now
    // (§6.2.1) — the same count never reaches the element loop at all: it is
    // refused at the count word, as a policy rejection distinct from INVALID.
    test('under a receiver cap the same count is limitExceeded', () {
      sofab.DecodeStatus capped(String hex) => sofab.Decoder.decode(
        hexToBytes(hex),
        CappedVisitor(maxArrayCount: 1024),
      );
      expect(capped('03$maxCount'), sofab.DecodeStatus.limitExceeded);
      expect(capped('0c$maxCount'), sofab.DecodeStatus.limitExceeded);
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
        sofab.Decoder.decode(hexToBytes('03${maxCount}010203'), rec),
        sofab.DecodeStatus.incomplete,
      );
      expect(rec.events.where((e) => e.startsWith('AU:')), isEmpty);
    });

    test('a length larger than the input never sizes a destination', () {
      // The fixlen twin of the cases above: a `string` announcing half a
      // gigabyte with none present. The one-shot surface knows the buffer
      // cannot back that length, so it never asks the caller for a destination
      // — no cap is involved, and none is needed.
      var asked = false;
      final st = sofab.Decoder.decode(
        hexToBytes('02f2ffffff0f'),
        _AskRecorder(() => asked = true),
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
