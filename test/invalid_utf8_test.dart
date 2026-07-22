import 'dart:io';

import 'package:sofabuffers/sofabuffers.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The negative `invalid_utf8` conformance vectors (CORELIB_PLAN §6.4). This
/// port is always strict (Dart `String` is a Unicode type), so it MUST:
///  - decode `serialized_hex` (with the string materialized) to INVALID, and
///  - refuse to encode an invalid string with InvalidArgument.
///
/// The wire-level (`serialized_hex`) decode check applies to every seed. The
/// encode-side check is expressed the way §6.4 specifies for a Unicode-string
/// target: via **unpaired surrogates** (the only invalid input a Dart `String`
/// can hold) — the byte-level overlong/out-of-range seeds cannot be represented
/// as a Dart `String` at all, so they are decode-side only here.
void main() {
  final root =
      decodeVectorJson(File('assets/test_vectors.json').readAsStringSync())
          as Map;
  final seeds = (root['invalid_utf8'] as List).cast<Map<String, dynamic>>();

  test('invalid_utf8 seed set is present', () {
    expect(seeds, isNotEmpty);
  });

  group('invalid_utf8 · strict decode → INVALID', () {
    for (final s in seeds) {
      final name = s['name'] as String;
      test(name, () {
        final bytes = hexToBytes(s['serialized_hex'] as String);
        // A visitor that reads (materializes) the string field.
        final rec = RecordingVisitor();
        final status = sofab.Decoder.decode(bytes, rec);
        expect(
          status,
          sofab.DecodeStatus.invalid,
          reason: 'strict decode of $name must be INVALID',
        );
      });
    }
  });

  group('invalid_utf8 · skipped string is never validated', () {
    // A skipped invalid-UTF-8 string must NOT be rejected (§6.4): skipping is a
    // length jump, no validation. The message then decodes cleanly.
    for (final s in seeds) {
      final name = s['name'] as String;
      final id = jInt(s['id']);
      test(name, () {
        final bytes = hexToBytes(s['serialized_hex'] as String);
        final rec = RecordingVisitor(skipIds: {id});
        final status = sofab.Decoder.decode(bytes, rec);
        expect(
          status,
          sofab.DecodeStatus.complete,
          reason: 'skipping id $id must not validate its bytes',
        );
        expect(rec.events, isEmpty);
      });
    }
  });

  group('strict encode → InvalidArgument (unpaired surrogates)', () {
    void expectRejected(String label, String bad) {
      test(label, () {
        expect(
          () => sofab.Encoder.encodeToBytes((e) => e.writeString(0, bad)),
          throwsA(
            isA<sofab.SofabException>().having(
              (e) => e.code,
              'code',
              sofab.SofabError.invalidArgument,
            ),
          ),
        );
      });
    }

    expectRejected('lone high surrogate', String.fromCharCode(0xD800));
    expectRejected('lone low surrogate', String.fromCharCode(0xDC00));
    expectRejected(
      'high surrogate not followed by low',
      String.fromCharCodes([0xD800, 0x41]),
    );
    expectRejected(
      'trailing high surrogate at end',
      String.fromCharCodes([0x41, 0xDBFF]),
    );
  });

  test('utf8Valid primitive rejects overlong / surrogate / >U+10FFFF', () {
    expect(sofab.utf8Valid(hexToBytes('c080')), isFalse); // overlong NUL
    expect(sofab.utf8Valid(hexToBytes('eda080')), isFalse); // surrogate D800
    expect(sofab.utf8Valid(hexToBytes('f4908080')), isFalse); // > U+10FFFF
    expect(sofab.utf8Valid(hexToBytes('ff')), isFalse); // invalid lead
    expect(sofab.utf8Valid(hexToBytes('00')), isTrue); // embedded NUL is valid
    expect(sofab.utf8Valid(hexToBytes('f09f9880')), isTrue); // 😀
  });
}
