import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// An integer array's DECLARED ELEMENT WIDTH, applied at the element.
///
/// MESSAGE_SPEC §7.1 makes an element outside its declared width invalid, and
/// §5.2 makes INVALID dominate INCOMPLETE: such an element is established by its
/// own bytes, so truncating the array behind it cannot downgrade the verdict.
/// The whole-array callbacks cannot express that — a guard over the assembled
/// `onSignedArray`/`onUnsignedArray` list only runs for an array that arrives —
/// so the bound travels into the decoder as
/// [sofab.MessageVisitor.onArrayElemBound] (generator#267, Crucible F-0043).
///
/// Every case here pairs with a control one step away, so what is pinned is the
/// ORDERING, not a blanket reject.
void main() {
  // Runs the same bytes through both decode paths — one-shot contiguous, and the
  // streaming state machine fed one byte at a time — and asserts they agree.
  // The two reach the verdict differently (the streaming path checks at the
  // element, the contiguous one walks the decoded prefix when the array fails),
  // so their agreeing is itself part of the contract.
  sofab.DecodeStatus bothPaths(String hex, _WidthVisitor Function() make) {
    final bytes = hexToBytes(hex);

    final contig = make();
    final cSt = _verdict(contig, sofab.Decoder.decode(bytes, contig));

    final stream = make();
    final dec = sofab.Decoder(stream);
    var last = sofab.DecodeStatus.complete;
    for (final b in bytes) {
      last = dec.feed([b]);
    }
    if (bytes.isEmpty) last = dec.feed(const []);
    final sSt = _verdict(stream, last);

    expect(sSt, cSt, reason: 'streaming and contiguous paths must agree');
    return cSt;
  }

  // id 1, signed array  -> header (1<<3)|4 = 0x0c
  // id 0, unsigned array-> header (0<<3)|3 = 0x03
  group('a truncated array is still decided by the elements in hand', () {
    test('signed over-width then truncated → INVALID', () {
      // Crucible width_elem_trunc: count 5, one element = zigzag(5208), end.
      expect(
        bothPaths('0c05b051', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('signed in-range then truncated → INCOMPLETE', () {
      // ctl_width_elem_inrange_trunc: the same cut, element 1. Nothing is
      // decided yet, so the truncation IS the verdict.
      expect(
        bothPaths('0c0502', _WidthVisitor.new),
        sofab.DecodeStatus.incomplete,
      );
    });

    test('unsigned over-width then truncated → INVALID', () {
      expect(
        bothPaths('03058004', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('unsigned in-range then truncated → INCOMPLETE', () {
      // 255 == the u8 bound.
      expect(
        bothPaths('0305ff01', _WidthVisitor.new),
        sofab.DecodeStatus.incomplete,
      );
    });

    test('an unsigned value above 2^63 is out of range, not negative', () {
      // Dart has no unsigned int: 0xffff_ffff_ffff_ffff arrives as -1, and a
      // bare `v > 255` would wave through exactly the largest wire values.
      expect(
        bothPaths('0305ffffffffffffffffff01', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });
  });

  group('an array that COMPLETES is decided by the same bound', () {
    // The hook's contract is "the decoder then applies the range as the
    // elements go past": an element outside its declared width is INVALID
    // wherever it sits (§7.1), not only where a truncation follows it. The
    // whole-array callbacks return `void`, so a visitor that answered the bound
    // has no channel left to reject through — leaving the completing array to
    // them made the two surfaces disagree on the same bytes (#38).
    test('unsigned over-width, array complete → INVALID on both paths', () {
      expect(
        bothPaths('03018004', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('signed over-width, array complete → INVALID on both paths', () {
      // zigzag(5208) = 0xb051, the same element the truncated case uses.
      expect(
        bothPaths('0c01b051', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('the rejected array is not handed to the visitor', () {
      final c = _WidthVisitor();
      expect(
        sofab.Decoder.decode(hexToBytes('03018004'), c),
        sofab.DecodeStatus.invalid,
      );
      expect(c.arrays, isEmpty);

      final s = _WidthVisitor();
      expect(
        sofab.Decoder(s).feed(hexToBytes('03018004')),
        sofab.DecodeStatus.invalid,
      );
      expect(s.arrays, isEmpty);
    });

    test('an over-width element in the word-wise loop is caught', () {
      // 13 elements, the offender first: long enough that the contiguous
      // decoder enters its 64-bit-load element loop (entered while a maximal
      // varint still fits) instead of running the scalar tail alone.
      expect(
        bothPaths('030d80040102030405060708090a0b0c', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('an over-width element in the scalar tail is caught', () {
      // The same 13 elements with the offender near the end, where the
      // word-wise loop has already handed over to the byte-wise tail.
      expect(
        bothPaths('030d0102030405060708090a0b80047f', _WidthVisitor.new),
        sofab.DecodeStatus.invalid,
      );
    });

    test('an in-range array still arrives, in full, on both paths', () {
      final c = _WidthVisitor();
      expect(
        sofab.Decoder.decode(hexToBytes('0303ff01007f'), c),
        sofab.DecodeStatus.complete,
      );
      expect(c.inv, isFalse);
      expect(c.arrays, [
        [255, 0, 127],
      ]);

      final s = _WidthVisitor();
      expect(
        sofab.Decoder(s).feed(hexToBytes('0303ff01007f')),
        sofab.DecodeStatus.complete,
      );
      expect(s.arrays, [
        [255, 0, 127],
      ]);
    });

    test('an id with no declared width is unaffected when it completes', () {
      // The control for the group: the same over-wide value at an id this
      // visitor declares nothing for stays a non-event.
      expect(
        bothPaths('13018004', _WidthVisitor.new),
        sofab.DecodeStatus.complete,
      );
    });
  });

  test('a contradicting wire kind is not measured against this bound', () {
    // id 1 declares SIGNED; an unsigned array arrives. §7.3 skips the field
    // whole, so its elements were never this field's value — 5208 must not be
    // measured against the i8 range.
    expect(
      bothPaths('0b05b051', _WidthVisitor.new),
      sofab.DecodeStatus.incomplete,
    );
  });

  test('an id with no declared width keeps today\'s outcome', () {
    expect(
      bothPaths('1405b051', _WidthVisitor.new),
      sofab.DecodeStatus.incomplete,
    );
  });

  test('a visitor that declares no bound at all is unaffected', () {
    // The additive contract: the vector that is INVALID above stays INCOMPLETE
    // for a visitor that does not override onArrayElemBound.
    final v = _PlainVisitor();
    expect(
      sofab.Decoder.decode(hexToBytes('0c05b051'), v),
      sofab.DecodeStatus.incomplete,
    );
  });

  test('an over-width element outranks even an impossible count', () {
    // Contiguous path only: the count here is ARRAY_MAX, which the streaming
    // decoder has no way to refute (it cannot know how many bytes still
    // follow) — §6.2.1's `maxArrayCount` is the instrument for that side. On
    // the one-shot surface the input itself refutes the count, but a decoder
    // that bailed on the count alone would lose the over-width element that
    // §5.2 says decides first.
    final v = _WidthVisitor();
    expect(
      _verdict(v, sofab.Decoder.decode(hexToBytes('0cffffffff07b051'), v)),
      sofab.DecodeStatus.invalid,
    );
  });

  test('the bound is asked once per array, never per element', () {
    final v = _CountingVisitor();
    sofab.Decoder.decode(hexToBytes('0c0402040608'), v);
    expect(v.asked, 1);
  });
}

/// The verdict a generated decoder reports: the sticky INVALID flag outranks the
/// status, exactly as the generated `inv ? invalid : status` does.
sofab.DecodeStatus _verdict(_PlainVisitor v, sofab.DecodeStatus st) =>
    v.inv ? sofab.DecodeStatus.invalid : st;

class _PlainVisitor extends sofab.MessageVisitor {
  bool inv = false;
  final List<List<int>> arrays = [];

  @override
  void onUnsignedArray(int id, Int64List values) => arrays.add(values.toList());

  @override
  void onSignedArray(int id, Int64List values) => arrays.add(values.toList());
}

/// A stand-in for generated code: `array<u8, count 5>` at id 0 and
/// `array<i8, count 5>` at id 1, nothing at id 2.
class _WidthVisitor extends _PlainVisitor {
  @override
  sofab.ElemRange? onArrayElemBound(int id, sofab.ArrayKind kind) {
    switch (id) {
      case 0:
        if (kind == sofab.ArrayKind.unsigned) {
          return const sofab.ElemRange(0, 255);
        }
        return null;
      case 1:
        if (kind == sofab.ArrayKind.signed) {
          return const sofab.ElemRange(-128, 127);
        }
        return null;
    }
    return null;
  }
}

class _CountingVisitor extends _PlainVisitor {
  int asked = 0;

  @override
  sofab.ElemRange? onArrayElemBound(int id, sofab.ArrayKind kind) {
    asked++;
    return const sofab.ElemRange(-128, 127);
  }
}
