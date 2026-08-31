import 'dart:io';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// The shared `sequence_growth` block (CORELIB_PLAN §7.1, §7.2 item 8).
///
/// A wrapper array's length is *highest present id + 1* (MESSAGE_SPEC §5.1), so
/// its size is known only when the array ends and its container grows as
/// elements arrive — "in the static helper / generated layer (§6.6.1), never in
/// the codec — the one allocation shape where growth is conformant".
///
/// Nothing else in the shared vectors reaches it: "two ports that grow
/// differently emit identical bytes and reach identical outcomes, so §7.1's
/// vectors are structurally blind to it". The cases are therefore keyed by a
/// **delivery sequence of element ids** rather than by bytes: this file builds
/// the message from `deliver` and asserts `expect`.
///
/// Indices are cap-relative. The cap is the port's own configured
/// `max_dyn_array_count` — here the collectors' `rcap`, which is what bounds a
/// wrapper array's element index in this port (CORELIB_PLAN §6.2.1). The block
/// assumes at least 4; [_cap] picks a small one so a case that grows to the cap
/// stays cheap.
void main() {
  const cap = 8;

  final root =
      decodeVectorJson(File('assets/test_vectors.json').readAsStringSync())
          as Map;
  final cases = (root['sequence_growth'] as List?)
      ?.cast<Map<String, dynamic>>();

  test('the sequence_growth block is present', () {
    expect(
      cases,
      isNotNull,
      reason: 'assets/test_vectors.json predates the sequence_growth block',
    );
    expect(cases, isNotEmpty);
  });

  if (cases == null) return;

  /// This port grows (`lib/src/seq.dart`), so no `requires` gating excludes it;
  /// what it does not implement would.
  const supported = {'sequence', 'fixlen', 'dynamic_arrays'};

  for (final c in cases) {
    final name = c['name'] as String;
    final requires = (c['requires'] as List).cast<String>();
    final elementType = c['element_type'] as String;
    final fieldId = jInt(c['field_id']);
    final deliver = (c['deliver'] as List).cast<Map<String, dynamic>>();
    final expected = (c['expect'] as Map).cast<String, dynamic>();

    test('$name (${c['group']})', () {
      for (final r in requires) {
        expect(
          supported,
          contains(r),
          reason: 'this port declares no such capability gate',
        );
      }

      /// The element index of one `deliver` entry: either absolute, or an
      /// offset from the port's own cap.
      int idOf(Map<String, dynamic> d) => d.containsKey('id_from_cap')
          ? cap + jInt(d['id_from_cap'])
          : jInt(d['id']);

      // Build the message: one wrapper array (a sequence at `field_id`) whose
      // elements are written at their own ids.
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(out.add, buffer: Uint8List(4096));
      enc.beginSequenceLazy(fieldId);
      for (final d in deliver) {
        final id = idOf(d);
        if (elementType == 'string') {
          enc.writeString(id, d['value'] as String);
        } else {
          // A struct element: a framed sub-sequence carrying one unsigned at
          // id 0. `endSequenceKeep`, because an element's frame is what carries
          // the array's length (MESSAGE_SPEC §5.1).
          enc.beginSequenceLazy(id);
          enc.writeUnsigned(0, jInt(d['value']));
          enc.endSequenceKeep();
        }
      }
      // `endSequenceKeep` on the wrapper: an array framed empty is one of the
      // cases, and only the keeping closer puts that frame on the wire
      // (§6.0.1). For every other case the frame is already committed by the
      // first element, so the closer makes no difference to the bytes.
      enc.endSequenceKeep();
      enc.flush();
      final bytes = out.takeBytes();

      // Decode into the collector for this element type, with the receiver cap
      // set and no schema `count` (cap = -1): §6.2.1 keeps a receiver cap off a
      // field the schema already bounds, so the two never both apply.
      final strings = <String>[];
      final structs = <_Elem>[];
      sofab.MessageVisitor collector() => elementType == 'string'
          ? sofab.StringSeq(
              strings,
              -1,
              -1,
              rcap: cap,
              relemMax: sofab.fixlenMax,
            )
          : sofab.MessageSeq<_Elem>(
              structs,
              -1,
              _Elem.new,
              (e) => _ElemVisitor(e),
              rcap: cap,
            );
      int length() => elementType == 'string' ? strings.length : structs.length;

      final st = sofab.Decoder.decode(bytes, _Root(fieldId, collector()));

      // ... and again through the streaming surface, one byte per feed, which
      // has to reach the same verdict and the same container.
      final strings2 = <String>[];
      final structs2 = <_Elem>[];
      final dec = sofab.Decoder(
        _Root(
          fieldId,
          elementType == 'string'
              ? sofab.StringSeq(
                  strings2,
                  -1,
                  -1,
                  rcap: cap,
                  relemMax: sofab.fixlenMax,
                )
              : sofab.MessageSeq<_Elem>(
                  structs2,
                  -1,
                  _Elem.new,
                  (e) => _ElemVisitor(e),
                  rcap: cap,
                ),
        ),
      );
      var streamSt = sofab.DecodeStatus.complete;
      for (final b in bytes) {
        streamSt = dec.feed([b]);
      }
      final streamLength = elementType == 'string'
          ? strings2.length
          : structs2.length;

      final want = switch (expected['outcome'] as String) {
        'complete' => sofab.DecodeStatus.complete,
        'incomplete' => sofab.DecodeStatus.incomplete,
        'invalid' => sofab.DecodeStatus.invalid,
        'limit_exceeded' => sofab.DecodeStatus.limitExceeded,
        final o => fail('unknown outcome $o'),
      };
      expect(st, want, reason: 'one-shot outcome');
      expect(streamSt, want, reason: 'streaming outcome');

      if (expected['terminal'] == true) {
        // A terminal verdict stays: feeding more cannot turn it back.
        expect(dec.feed(const [0x00]), want);
      }
      if (expected.containsKey('length')) {
        expect(length(), jInt(expected['length']), reason: 'container length');
        expect(streamLength, jInt(expected['length']));
      }
      if (expected.containsKey('length_from_cap')) {
        final want = cap + jInt(expected['length_from_cap']);
        expect(length(), want, reason: 'container length (cap-relative)');
        expect(streamLength, want);
      }
      if (expected.containsKey('max_length')) {
        // "the container is not left partially extended": nothing beyond what
        // legitimately arrived before the rejection.
        final limit = jInt(expected['max_length']);
        expect(length(), lessThanOrEqualTo(limit), reason: 'no partial extend');
        expect(streamLength, lessThanOrEqualTo(limit));
      }
      for (final idx in (expected['default_ids'] as List? ?? const [])) {
        final i = jInt(idx);
        if (elementType == 'string') {
          expect(strings[i], '', reason: 'gap at $i holds the element default');
          expect(strings2[i], '');
        } else {
          expect(structs[i].value, 0);
        }
      }
    });
  }
}

/// The element of a `struct` wrapper array: one unsigned field at id 0.
class _Elem {
  int value = 0;
}

class _ElemVisitor extends sofab.VisitorBase {
  _ElemVisitor(this.o);
  final _Elem o;

  @override
  void onUnsigned(int id, int v) {
    if (id == 0) o.value = v;
  }
}

/// Routes the one wrapper-array field to the collector under test.
class _Root extends sofab.VisitorBase {
  _Root(this.fieldId, this.child);
  final int fieldId;
  final sofab.MessageVisitor child;

  @override
  sofab.MessageVisitor? onSequenceStart(int id) => id == fieldId ? child : null;
}
