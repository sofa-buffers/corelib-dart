import 'dart:io';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// Strict UTF-8 (CORELIB_PLAN §6.4) through the **streaming** decoder.
///
/// The shared `invalid_utf8` vectors are decisive about *what* is invalid, but
/// every one of them is a whole message of at most six bytes whose bad sequence
/// sits at payload offset 0. Feeding them one-shot therefore exercises exactly
/// one arrival shape, and a port that validated only the bytes it happened to
/// hold at the moment it first looked — or that scanned from a cursor it
/// advanced with the wrong offset — would pass every one of them.
///
/// The gap this file closes is the arrival shape the vectors cannot express: an
/// invalid sequence that **begins at a payload offset at or beyond everything
/// fed so far**, so that at the point it arrives, every byte the decoder has
/// already seen was valid UTF-8. That is the case where "validate what is new"
/// and "validate the payload" come apart, and it is only reachable by choosing
/// the chunk boundaries — which is what these tests do, seed by seed, on top of
/// a long valid prefix.
void main() {
  final root =
      decodeVectorJson(File('assets/test_vectors.json').readAsStringSync())
          as Map;
  final seeds = (root['invalid_utf8'] as List).cast<Map<String, dynamic>>();

  /// The bad byte sequence of a seed, stripped of the message framing: parse
  /// the field header and the `fixlen_word` off `serialized_hex` and keep the
  /// payload. Derived from the shared vectors rather than restated here, so a
  /// new seed is picked up by every test below without being copied.
  Uint8List seedPayload(Map<String, dynamic> s) {
    final wire = hexToBytes(s['serialized_hex'] as String);
    var p = 0;
    int varint() {
      var v = 0, shift = 0;
      while (true) {
        final b = wire[p++];
        v |= (b & 0x7F) << shift;
        if (b & 0x80 == 0) return v;
        shift += 7;
      }
    }

    final header = varint();
    expect(
      header & 0x7,
      sofab.WireType.fixlen,
      reason: 'a utf8 seed is a fixlen field',
    );
    final word = varint();
    expect(
      word & 0x7,
      sofab.FixlenType.string,
      reason: 'subtype must be string',
    );
    final payload = Uint8List.sublistView(wire, p);
    expect(word >>> 3, payload.length, reason: 'seed length must match');
    expect(sofab.utf8Valid(payload), isFalse, reason: 'the seed must be bad');
    return payload;
  }

  // --- message construction ------------------------------------------------

  void putVarint(BytesBuilder b, int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7F) | 0x80);
      v >>>= 7;
    }
    b.addByte(v);
  }

  /// A one-field message carrying [payload] as the raw wire bytes of a `string`
  /// field with id [id]. Built here rather than with `writeString`, because the
  /// encoder is strict and would (correctly) refuse to produce these bytes.
  Uint8List stringMessage(int id, List<int> payload) {
    final b = BytesBuilder();
    putVarint(b, (id << 3) | sofab.WireType.fixlen);
    putVarint(b, (payload.length << 3) | sofab.FixlenType.string);
    b.add(payload);
    return b.toBytes();
  }

  /// Feeds [chunks] in order and returns the last status. Feeding continues
  /// past a terminal verdict on purpose: a decoder that has said `invalid` must
  /// keep saying it (§5.2, terminal).
  sofab.DecodeStatus feedAll(sofab.Decoder d, List<List<int>> chunks) {
    var st = sofab.DecodeStatus.complete;
    for (final c in chunks) {
      st = d.feed(c);
    }
    return st;
  }

  /// Feeds [bytes] one byte per `feed` call.
  sofab.DecodeStatus feedByteWise(sofab.Decoder d, Uint8List bytes) =>
      feedAll(d, [
        for (final b in bytes) <int>[b],
      ]);

  // 96 bytes of unimpeachable ASCII: long enough that the interesting boundary
  // is nowhere near the message start, and long enough to take the decoder's
  // bulk-payload path before the bad bytes arrive.
  final prefix = Uint8List.fromList(List<int>.filled(96, 0x61)); // 'a'
  // A valid multi-byte tail, so the payload does not *end* at the bad bytes
  // either: 'ä' + '€' + '😀'.
  final suffix = Uint8List.fromList(const [
    0xC3, 0xA4, //
    0xE2, 0x82, 0xAC, //
    0xF0, 0x9F, 0x98, 0x80,
  ]);

  test('the fixtures are what the tests assume', () {
    // Guards every "→ INVALID" below from passing for the wrong reason: the
    // frame and both halves of the padding are valid on their own.
    expect(seeds, isNotEmpty);
    expect(sofab.utf8Valid(prefix), isTrue);
    expect(sofab.utf8Valid(suffix), isTrue);
    final rec = RecordingVisitor();
    final good = stringMessage(1, prefix + suffix);
    expect(sofab.Decoder.decode(good, rec), sofab.DecodeStatus.complete);
    expect(rec.events.single, 'STR:1:${'a' * 96}ä€😀');
  });

  // -------------------------------------------------------------------------
  // The gap: the bad sequence starts at or beyond the total fed so far.
  // -------------------------------------------------------------------------

  group('invalid_utf8 · bad sequence begins beyond everything fed so far', () {
    for (final s in seeds) {
      final name = s['name'] as String;

      test('$name · first byte of the bad sequence opens the next chunk', () {
        final bad = seedPayload(s);
        final wire = stringMessage(1, prefix + bad + suffix);
        // The cut lands exactly where the bad sequence begins: chunk 1 is the
        // frame plus 96 valid bytes, so at the moment chunk 2 arrives every
        // byte the decoder has consumed was valid UTF-8 and the bad sequence
        // starts at payload offset 96 == the payload total fed so far.
        final cut = wire.length - bad.length - suffix.length;
        final rec = RecordingVisitor();
        final dec = sofab.Decoder(rec);
        expect(
          dec.feed(Uint8List.sublistView(wire, 0, cut)),
          sofab.DecodeStatus.incomplete,
          reason: 'the valid prefix alone is a short payload, not a verdict',
        );
        expect(
          dec.feed(Uint8List.sublistView(wire, cut)),
          sofab.DecodeStatus.invalid,
          reason: '$name arriving late is still $name',
        );
        expect(rec.events, isEmpty, reason: 'nothing may be delivered');
      });

      test('$name · arriving one byte at a time after the prefix', () {
        // Same boundary, then the bad sequence itself dribbles in — so no feed
        // ever holds it whole and each byte is at an offset past the last.
        final bad = seedPayload(s);
        final wire = stringMessage(1, prefix + bad + suffix);
        final cut = wire.length - bad.length - suffix.length;
        final rec = RecordingVisitor();
        final dec = sofab.Decoder(rec);
        dec.feed(Uint8List.sublistView(wire, 0, cut));
        final st = feedByteWise(dec, Uint8List.sublistView(wire, cut));
        expect(st, sofab.DecodeStatus.invalid);
        expect(rec.events, isEmpty);
      });

      test('$name · split at every byte of the message', () {
        // Every boundary, not just the interesting one: the verdict may not
        // depend on where the chunks fall.
        final bad = seedPayload(s);
        final wire = stringMessage(1, prefix + bad + suffix);
        for (var cut = 0; cut <= wire.length; cut++) {
          final rec = RecordingVisitor();
          final dec = sofab.Decoder(rec);
          final st = feedAll(dec, [
            Uint8List.sublistView(wire, 0, cut),
            Uint8List.sublistView(wire, cut),
          ]);
          expect(
            st,
            sofab.DecodeStatus.invalid,
            reason: '$name must be INVALID when split at $cut',
          );
          expect(
            rec.events,
            isEmpty,
            reason: 'split at $cut delivered a value',
          );
        }
      });
    }
  });

  // -------------------------------------------------------------------------
  // The seeds themselves, chunked — the vectors' own bytes, fed the hard way.
  // -------------------------------------------------------------------------

  group('invalid_utf8 · the shared seed messages, chunked', () {
    for (final s in seeds) {
      final name = s['name'] as String;
      final id = jInt(s['id']);

      test('$name · one byte at a time → INVALID', () {
        final wire = hexToBytes(s['serialized_hex'] as String);
        final rec = RecordingVisitor();
        final dec = sofab.Decoder(rec);
        expect(feedByteWise(dec, wire), sofab.DecodeStatus.invalid);
        expect(rec.events, isEmpty);
      });

      test('$name · skipped, one byte at a time → COMPLETE', () {
        // §6.4: a skipped string is a length jump, never validated — and that
        // has to hold when the length jump is spread over many feeds, where a
        // skip implemented as "walk and validate" would trip.
        final wire = hexToBytes(s['serialized_hex'] as String);
        final rec = RecordingVisitor(skipIds: {id});
        final dec = sofab.Decoder(rec);
        expect(feedByteWise(dec, wire), sofab.DecodeStatus.complete);
        expect(rec.events, isEmpty);
      });
    }

    test('a long skipped payload with a late bad sequence stays COMPLETE', () {
      // The skip twin of the gap case, at a size that takes the bulk skip path.
      final bad = seedPayload(seeds.first);
      final wire = stringMessage(1, prefix + bad + suffix);
      final cut = wire.length - bad.length - suffix.length;
      final rec = RecordingVisitor(skipIds: {1});
      final dec = sofab.Decoder(rec);
      dec.feed(Uint8List.sublistView(wire, 0, cut));
      expect(
        dec.feed(Uint8List.sublistView(wire, cut)),
        sofab.DecodeStatus.complete,
      );
      expect(rec.events, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The raw-bytes path, which is what makes the offset question moot here.
  // -------------------------------------------------------------------------

  test('a schema-bound consumer is handed the whole payload, not a chunk', () {
    // `onStringBytes` is the port's string path (§6.4). Whatever the chunking,
    // it must fire exactly once with the *entire* reassembled payload — that is
    // the mechanism that puts "an offset beyond what was fed" out of reach, and
    // it is worth asserting directly rather than only through its consequence.
    final bad = seedPayload(seeds.first);
    final payload = Uint8List.fromList(prefix + bad + suffix);
    final wire = stringMessage(1, payload);
    for (final chunkSize in const [1, 7, 96, 1000]) {
      final seen = <Uint8List>[];
      final dec = sofab.Decoder(_RawStringVisitor(seen));
      for (var i = 0; i < wire.length; i += chunkSize) {
        final end = i + chunkSize < wire.length ? i + chunkSize : wire.length;
        dec.feed(Uint8List.sublistView(wire, i, end));
      }
      expect(seen, hasLength(1), reason: 'chunk size $chunkSize');
      expect(seen.single, payload, reason: 'chunk size $chunkSize');
      expect(sofab.utf8Valid(seen.single), isFalse);
    }
  });

  // -------------------------------------------------------------------------
  // The other direction: a boundary inside a *valid* sequence must be harmless.
  // -------------------------------------------------------------------------

  test('a chunk boundary inside a valid multi-byte sequence is harmless', () {
    // The mirror of the gap: cutting a 2-, 3- and 4-byte sequence at every one
    // of its interior boundaries must still transcode to the same string. A
    // validator that resumed at the wrong offset would either reject these or
    // corrupt them, and no vector covers it because no vector is chunked.
    const text = 'aä€😀b';
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeString(1, text));
    for (var cut = 0; cut <= wire.length; cut++) {
      final rec = RecordingVisitor();
      final dec = sofab.Decoder(rec);
      final st = feedAll(dec, [
        Uint8List.sublistView(wire, 0, cut),
        Uint8List.sublistView(wire, cut),
      ]);
      expect(st, sofab.DecodeStatus.complete, reason: 'split at $cut');
      expect(rec.events.single, 'STR:1:$text', reason: 'split at $cut');
    }
  });

  test('a valid string arriving one byte at a time transcodes exactly', () {
    const text = 'aä€😀b';
    final wire = sofab.Encoder.encodeToBytes((e) => e.writeString(1, text));
    final rec = RecordingVisitor();
    final dec = sofab.Decoder(rec);
    expect(feedByteWise(dec, wire), sofab.DecodeStatus.complete);
    expect(rec.events.single, 'STR:1:$text');
  });

  // -------------------------------------------------------------------------
  // Terminality: the verdict does not un-say itself.
  // -------------------------------------------------------------------------

  test('INVALID from a late bad sequence is terminal', () {
    final bad = seedPayload(seeds.first);
    final wire = stringMessage(1, prefix + bad);
    final trailer = sofab.Encoder.encodeToBytes((e) => e.writeUnsigned(2, 7));
    final rec = RecordingVisitor();
    final dec = sofab.Decoder(rec);
    final cut = wire.length - bad.length;
    expect(
      dec.feed(Uint8List.sublistView(wire, 0, cut)),
      sofab.DecodeStatus.incomplete,
    );
    expect(
      dec.feed(Uint8List.sublistView(wire, cut)),
      sofab.DecodeStatus.invalid,
    );
    // Perfectly good bytes afterwards must not resurrect the decode, and must
    // not be delivered either.
    expect(dec.feed(trailer), sofab.DecodeStatus.invalid);
    expect(dec.feed(const <int>[]), sofab.DecodeStatus.invalid);
    expect(rec.events, isEmpty);
  });
}

/// Captures the raw wire bytes of every materialized `string` field, taking a
/// copy: the decoder's view is only valid for the duration of the call.
class _RawStringVisitor extends sofab.MessageVisitor {
  _RawStringVisitor(this.seen);
  final List<Uint8List> seen;

  @override
  void onStringBytes(int id, Uint8List bytes) =>
      seen.add(Uint8List.fromList(bytes));
}
