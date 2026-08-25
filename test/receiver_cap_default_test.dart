import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The receiver-side caps are **finite by default** (CORELIB_PLAN §6.2.1).
///
/// *"Every receiver MUST carry generic maximum limits … There is no unset state
/// and no unlimited mode. Unbounded by the schema is still bounded by the
/// receiver."* A decoder built with no [sofab.DecoderLimits] at all is still a
/// receiver, so it is still bounded — and the enforcement point is the
/// count/length header, *"before the allocation it is meant to prevent"*.
///
/// The case that gave this file its name: seven bytes declaring an
/// `array<fp64>` of `ARRAY_MAX` elements. Against an unbounded default the
/// streaming decoder asked the VM for 17 GB and died with an `OutOfMemoryError`
/// thrown out of `feed`; the one-shot decoder survived only because it sized the
/// result from the bytes in hand. Both now refuse the count where it is read.
void main() {
  /// The seven bytes: field 1, wire type array_fixlen, `element_count` =
  /// ARRAY_MAX, `fixlen_word` = fp64 (8 bytes/element).
  final bomb = hexToBytes('0dffffffff0741');

  group('an unconfigured decoder is bounded', () {
    test('the streaming surface refuses the count at the header', () {
      final dec = sofab.Decoder(RecordingVisitor());
      expect(dec.feed(bomb), sofab.DecodeStatus.limitExceeded);
    });

    test('byte at a time reaches the same verdict', () {
      final dec = sofab.Decoder(RecordingVisitor());
      var st = sofab.DecodeStatus.complete;
      for (final b in bomb) {
        st = dec.feed([b]);
      }
      expect(st, sofab.DecodeStatus.limitExceeded);
    });

    test('the one-shot surface refuses it too', () {
      expect(
        sofab.Decoder.decode(bomb, RecordingVisitor()),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('the verdict is terminal and stays limitExceeded', () {
      final dec = sofab.Decoder(RecordingVisitor());
      expect(dec.feed(bomb), sofab.DecodeStatus.limitExceeded);
      expect(dec.feed(hexToBytes('00')), sofab.DecodeStatus.limitExceeded);
    });

    test('an integer array over the default count cap', () {
      // id 0, array_unsigned, count = ARRAY_MAX.
      final bytes = hexToBytes('03ffffffff07');
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor()),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(
        sofab.Decoder(RecordingVisitor()).feed(bytes),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('a string length over the default string cap', () {
      // id 0, fixlen, fixlen_word = (FIXLEN_MAX << 3) | string.
      final bytes = hexToBytes('02f2ffffff0f');
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor()),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(
        sofab.Decoder(RecordingVisitor()).feed(bytes),
        sofab.DecodeStatus.limitExceeded,
      );
    });

    test('a blob length over the default blob cap', () {
      // id 0, fixlen, fixlen_word = (FIXLEN_MAX << 3) | blob.
      final bytes = hexToBytes('02fbffffff0f');
      expect(
        sofab.Decoder.decode(bytes, RecordingVisitor()),
        sofab.DecodeStatus.limitExceeded,
      );
      expect(
        sofab.Decoder(RecordingVisitor()).feed(bytes),
        sofab.DecodeStatus.limitExceeded,
      );
    });
  });

  group('the defaults are values, not a switch', () {
    test('all three are finite and positive', () {
      const l = sofab.DecoderLimits();
      expect(l.maxArrayCount, sofab.defaultMaxDynArrayCount);
      expect(l.maxStringLen, sofab.defaultMaxDynStringLen);
      expect(l.maxBlobLen, sofab.defaultMaxDynBlobLen);
      expect(l.maxArrayCount, greaterThan(0));
      expect(l.maxStringLen, greaterThan(0));
      expect(l.maxBlobLen, greaterThan(0));
      expect(l.maxArrayCount, lessThan(sofab.arrayMax));
      expect(l.maxStringLen, lessThan(sofab.fixlenMax));
      expect(l.maxBlobLen, lessThan(sofab.fixlenMax));
    });

    test('a deployment can raise one, and the count is then admitted', () {
      // The same seven bytes, with the cap wound out to the format ceiling:
      // now nothing is over any limit and the message is merely truncated.
      expect(
        sofab.Decoder.decode(
          bomb,
          RecordingVisitor(),
          limits: const sofab.DecoderLimits(maxArrayCount: sofab.arrayMax),
        ),
        sofab.DecodeStatus.incomplete,
      );
    });

    test('a negative cap is rejected, not read as unlimited', () {
      expect(
        () => sofab.DecoderLimits(maxArrayCount: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sofab.DecoderLimits(maxStringLen: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sofab.DecoderLimits(maxBlobLen: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  test('a skipped field is never capped (§6.2.1)', () {
    // The same over-cap array, at an id the visitor declines at header time:
    // it is walked, not materialized, so no allocation exists to bound and the
    // outcome is the truncation.
    expect(
      sofab.Decoder.decode(bomb, RecordingVisitor(skipIds: const {1})),
      sofab.DecodeStatus.incomplete,
    );
    final dec = sofab.Decoder(RecordingVisitor(skipIds: const {1}));
    expect(dec.feed(bomb), sofab.DecodeStatus.incomplete);
  });

  test('a cap breach is not INVALID, and is told apart from one', () {
    // Well-formed bytes over a limit → limitExceeded; malformed bytes →
    // invalid. §6.2.1 forbids folding the first into the second.
    expect(
      sofab.Decoder.decode(bomb, RecordingVisitor()),
      sofab.DecodeStatus.limitExceeded,
    );
    // fixlen_word with a reserved subtype (0x4) is malformed, whatever the caps.
    expect(
      sofab.Decoder.decode(hexToBytes('0224'), RecordingVisitor()),
      sofab.DecodeStatus.invalid,
    );
  });

  test('a payload under every cap still decodes', () {
    final bytes = Uint8List.fromList([0x02, 0x1a, 0x61, 0x62, 0x63]);
    final rec = RecordingVisitor();
    expect(sofab.Decoder.decode(bytes, rec), sofab.DecodeStatus.complete);
    expect(rec.events, ['STR:0:abc']);
  });
}
