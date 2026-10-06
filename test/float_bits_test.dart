import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

/// `floatBitsEqual`: array equality on IEEE-754 bit patterns, the default test
/// a generated encoder applies to a float array field (generator#636).
///
/// Not wire-visible, so the shared vectors cannot reach it; these unit tests do.
void main() {
  // The reference: a plain bit loop over the held doubles, no `==` on doubles.
  bool ref64(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    final x = Float64List.fromList(a).buffer.asUint8List();
    final y = Float64List.fromList(b).buffer.asUint8List();
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  double f64FromBits(int bits) =>
      (Int64List(1)..[0] = bits).buffer.asFloat64List()[0];
  double f32FromBits(int bits) =>
      (Uint32List(1)..[0] = bits).buffer.asFloat32List()[0];

  // The same value sequence in every container shape the call site can hold.
  final shapes = <String, List<double> Function(List<double>)>{
    'Float32List': (v) => Float32List.fromList(v),
    'Float64List': (v) => Float64List.fromList(v),
    'List<double>': (v) => List<double>.of(v),
    'const-like unmodifiable': (v) => List<double>.unmodifiable(v),
  };

  for (final MapEntry(key: name, value: make) in shapes.entries) {
    group('over $name', () {
      bool eq(List<double> a, List<double> b, {int? length}) =>
          sofab.floatBitsEqual(make(a), make(b), length: length);

      test('empty arrays are equal', () {
        expect(eq(const [], const []), isTrue);
      });

      test('one element', () {
        expect(eq(const [1.5], const [1.5]), isTrue);
        expect(eq(const [1.5], const [2.5]), isFalse);
      });

      test('equal arrays, and an array against itself', () {
        expect(eq(const [0.0, 1.5, -2.25], const [0.0, 1.5, -2.25]), isTrue);
        final a = make(const [0.0, 1.5]);
        expect(sofab.floatBitsEqual(a, a), isTrue);
      });

      test(
        '-0.0 differs from +0.0 at the first, a middle and the last index',
        () {
          for (final i in [0, 1, 2]) {
            final z = [0.0, 0.0, 0.0];
            final n = [0.0, 0.0, 0.0]..[i] = -0.0;
            expect(eq(n, z), isFalse, reason: 'index $i');
            expect(eq(z, n), isFalse, reason: 'index $i');
            expect(eq(n, n), isTrue, reason: 'index $i');
          }
          expect(eq(const [-0.0, 1.5], const [0.0, 1.5]), isFalse);
        },
      );

      test('the same NaN pattern is equal, so NaN is not != itself', () {
        expect(eq([double.nan, 1.0], [double.nan, 1.0]), isTrue);
      });

      test('infinities, and subnormals as the bits they are', () {
        final inf = double.infinity;
        expect(eq([inf, -inf], [inf, -inf]), isTrue);
        expect(eq([inf], [-inf]), isFalse);
        final sub = f32FromBits(1); // smallest fp32 subnormal, exact in fp64
        expect(eq([sub, -sub], [sub, -sub]), isTrue);
        expect(eq([sub], [-sub]), isFalse);
        expect(eq([sub], [0.0]), isFalse);
      });

      test('length mismatch in both directions', () {
        expect(eq(const [1.0, 2.0], const [1.0, 2.0, 3.0]), isFalse);
        expect(eq(const [1.0, 2.0, 3.0], const [1.0, 2.0]), isFalse);
        expect(eq(const [], const [0.0]), isFalse);
        expect(eq(const [0.0], const []), isFalse);
      });

      test(
        'long arrays: exactly one differing element at start, middle, end',
        () {
          final base = List<double>.generate(200, (i) => i * 0.5 - 40);
          expect(eq(base, base), isTrue);
          for (final i in [0, 100, 199]) {
            final d = List<double>.of(base)..[i] = base[i] + 1;
            expect(eq(base, d), isFalse, reason: 'value at $i');
            final z = List<double>.of(base)..[i] = 0.0;
            final nz = List<double>.of(base)..[i] = -0.0;
            expect(eq(z, nz), isFalse, reason: 'sign at $i');
          }
        },
      );

      test('length: compares only that prefix of the first array', () {
        final a = make(const [0.0, 1.5, 9.0, 9.0]);
        final b = make(const [0.0, 1.5]);
        expect(sofab.floatBitsEqual(a, b, length: 2), isTrue);
        expect(sofab.floatBitsEqual(a, b, length: 3), isFalse);
        expect(sofab.floatBitsEqual(a, b), isFalse);
        final c = make(const [-0.0, 1.5, 9.0, 9.0]);
        expect(sofab.floatBitsEqual(c, b, length: 2), isFalse);
        expect(sofab.floatBitsEqual(a, make(const []), length: 0), isTrue);
      });

      test('length outside 0..a.length is a RangeError', () {
        final a = make(const [1.0, 2.0]);
        expect(() => sofab.floatBitsEqual(a, a, length: 3), throwsRangeError);
        expect(() => sofab.floatBitsEqual(a, a, length: -1), throwsRangeError);
      });
    });
  }

  group('typed-list views', () {
    test(
      'a sublist view at a non-zero offset is compared at its own bytes',
      () {
        final big = Float32List.fromList([9, 9, 0.0, 1.5, 9]);
        final sub = Float32List.sublistView(big, 2, 4);
        expect(
          sofab.floatBitsEqual(sub, Float32List.fromList([0.0, 1.5])),
          isTrue,
        );
        expect(
          sofab.floatBitsEqual(sub, Float32List.fromList([-0.0, 1.5])),
          isFalse,
        );
        final big64 = Float64List.fromList([9, 0.0, 1.5, 9]);
        final sub64 = Float64List.sublistView(big64, 1, 3);
        expect(
          sofab.floatBitsEqual(sub64, Float64List.fromList([0.0, 1.5])),
          isTrue,
        );
        expect(
          sofab.floatBitsEqual(sub64, Float64List.fromList([0.0, -1.5])),
          isFalse,
        );
      },
    );

    test('Float32List against Float64List compares the widened pattern', () {
      expect(
        sofab.floatBitsEqual(
          Float32List.fromList([0.0, 1.5]),
          Float64List.fromList([0.0, 1.5]),
        ),
        isTrue,
      );
      expect(
        sofab.floatBitsEqual(
          Float32List.fromList([-0.0]),
          Float64List.fromList([0.0]),
        ),
        isFalse,
      );
    });
  });

  group('NaN payloads', () {
    test('fp64: a different payload or sign is not equal, the same is', () {
      final a = f64FromBits(0x7FF8000000000001);
      final b = f64FromBits(0x7FF8000000000002);
      final c = f64FromBits(0xFFF8000000000001);
      for (final make in [
        (List<double> v) => Float64List.fromList(v),
        (List<double> v) => List<double>.of(v),
      ]) {
        expect(sofab.floatBitsEqual(make([a]), make([a])), isTrue);
        expect(sofab.floatBitsEqual(make([a]), make([b])), isFalse);
        expect(sofab.floatBitsEqual(make([a]), make([c])), isFalse);
      }
    });

    test('fp32: payloads, and a signaling NaN against its quiet twin', () {
      // Built from raw bits: reading an fp32 sNaN into a double may quiet it,
      // which is what the 32-bit view exists to avoid.
      Float32List l(List<int> bits) =>
          Float32List.view(Uint32List.fromList(bits).buffer);
      expect(sofab.floatBitsEqual(l([0x7FC00001]), l([0x7FC00001])), isTrue);
      expect(sofab.floatBitsEqual(l([0x7FC00001]), l([0x7FC00002])), isFalse);
      expect(sofab.floatBitsEqual(l([0x7F800001]), l([0x7F800001])), isTrue);
      expect(sofab.floatBitsEqual(l([0x7F800001]), l([0x7FC00001])), isFalse);
    });
  });

  group(
    'Float32ArrayDefault / Float64ArrayDefault (the generated default test)',
    () {
      double f64FromBits(int bits) =>
          (Int64List(1)..[0] = bits).buffer.asFloat64List()[0];
      Float32List f32Bits(List<int> bits) =>
          Float32List.view(Uint32List.fromList(bits).buffer);

      // matches() against the plain bit loop, on both widths.
      bool ref(List<double> a, int n, List<double> d) {
        if (n != d.length) return false;
        final x =
            (a is Float32List
                    ? Float32List.fromList(a.sublist(0, n))
                    : Float64List.fromList(a.sublist(0, n)))
                .buffer
                .asUint8List();
        final y =
            (d is Float32List
                    ? Float32List.fromList(d)
                    : Float64List.fromList(d))
                .buffer
                .asUint8List();
        for (var i = 0; i < x.length; i++) {
          if (x[i] != y[i]) return false;
        }
        return true;
      }

      test('list is a typed copy of the values', () {
        final d32 = sofab.Float32ArrayDefault(const [0.0, 1.5]);
        final d64 = sofab.Float64ArrayDefault(const [0.0, 1.5]);
        expect(d32.list, Float32List.fromList([0.0, 1.5]));
        expect(d64.list, Float64List.fromList([0.0, 1.5]));
      });

      test('a default without zeros: the plain loop decides', () {
        final d32 = sofab.Float32ArrayDefault(const [1.5, -2.25, 3.0]);
        final d64 = sofab.Float64ArrayDefault(const [1.5, -2.25, 3.0]);
        expect(
          d32.matches(Float32List.fromList([1.5, -2.25, 3.0, 9]), 3),
          isTrue,
        );
        expect(
          d64.matches(Float64List.fromList([1.5, -2.25, 3.0, 9]), 3),
          isTrue,
        );
        expect(
          d32.matches(Float32List.fromList([1.5, -2.25, 3.5]), 3),
          isFalse,
        );
        expect(
          d64.matches(Float64List.fromList([2.5, -2.25, 3.0]), 3),
          isFalse,
        );
        // a NaN in the field is a mismatch, and so is a zero
        expect(
          d64.matches(Float64List.fromList([double.nan, -2.25, 3.0]), 3),
          isFalse,
        );
        expect(d32.matches(Float32List.fromList([1.5, 0.0, 3.0]), 3), isFalse);
      });

      test('+0.0 in the default: -0.0 in the field is not the default', () {
        final d32 = sofab.Float32ArrayDefault(const [0.0, 1.5, 0.0]);
        final d64 = sofab.Float64ArrayDefault(const [0.0, 1.5, 0.0]);
        expect(d32.matches(Float32List.fromList([0.0, 1.5, 0.0]), 3), isTrue);
        expect(d64.matches(Float64List.fromList([0.0, 1.5, 0.0]), 3), isTrue);
        for (final i in [0, 2]) {
          final v = [0.0, 1.5, 0.0]..[i] = -0.0;
          expect(
            d32.matches(Float32List.fromList(v), 3),
            isFalse,
            reason: 'f32 $i',
          );
          expect(
            d64.matches(Float64List.fromList(v), 3),
            isFalse,
            reason: 'f64 $i',
          );
        }
      });

      test('-0.0 in the default: +0.0 in the field is not the default', () {
        final d32 = sofab.Float32ArrayDefault(const [-0.0, 2.0, -0.0, -0.0]);
        final d64 = sofab.Float64ArrayDefault(const [-0.0, 2.0, -0.0, -0.0]);
        expect(
          d32.matches(Float32List.fromList([-0.0, 2.0, -0.0, -0.0]), 4),
          isTrue,
        );
        expect(
          d64.matches(Float64List.fromList([-0.0, 2.0, -0.0, -0.0]), 4),
          isTrue,
        );
        for (final i in [0, 2, 3]) {
          final v = [-0.0, 2.0, -0.0, -0.0]..[i] = 0.0;
          expect(
            d32.matches(Float32List.fromList(v), 4),
            isFalse,
            reason: 'f32 $i',
          );
          expect(
            d64.matches(Float64List.fromList(v), 4),
            isFalse,
            reason: 'f64 $i',
          );
        }
      });

      test('mixed zero signs, past the first zero', () {
        const dv = [0.0, 1.0, -0.0, 0.0, -0.0];
        final d64 = sofab.Float64ArrayDefault(dv);
        expect(d64.matches(Float64List.fromList(dv), 5), isTrue);
        for (var i = 0; i < 5; i++) {
          if (dv[i] != 0) continue;
          final v = List<double>.of(dv)..[i] = dv[i].isNegative ? 0.0 : -0.0;
          expect(
            d64.matches(Float64List.fromList(v), 5),
            isFalse,
            reason: '$i',
          );
        }
      });

      test(
        'the prefix: storage beyond n takes no part, n must equal the length',
        () {
          final d32 = sofab.Float32ArrayDefault(const [0.0, 1.5]);
          final d64 = sofab.Float64ArrayDefault(const [0.0, 1.5]);
          expect(
            d32.matches(Float32List.fromList([0.0, 1.5, 7, 7]), 2),
            isTrue,
          );
          expect(
            d64.matches(Float64List.fromList([0.0, 1.5, 7, 7]), 2),
            isTrue,
          );
          expect(
            d32.matches(Float32List.fromList([0.0, 1.5, 7, 7]), 3),
            isFalse,
          );
          expect(
            d64.matches(Float64List.fromList([0.0, 1.5, 7, 7]), 1),
            isFalse,
          );
          expect(d64.matches(Float64List(4), 0), isFalse);
        },
      );

      test('a zero inside the default splits the loop where it is', () {
        // The element at the first zero index is read once, by the loop, and
        // its sign tested there; a NaN at that index is a mismatch, and so is
        // any element before or after it.
        for (final neg in [false, true]) {
          final z = neg ? -0.0 : 0.0;
          final d32 = sofab.Float32ArrayDefault([1.5, 2.5, z, 3.5]);
          final d64 = sofab.Float64ArrayDefault([1.5, 2.5, z, 3.5]);
          for (final v in <List<double>>[
            [1.5, 2.5, -z, 3.5],
            [1.5, 2.5, double.nan, 3.5],
            [1.5, 2.5, 1e-45, 3.5],
            [9.0, 2.5, z, 3.5],
            [1.5, 2.5, z, 9.0],
          ]) {
            expect(d32.matches(Float32List.fromList(v), 4), isFalse);
            expect(d64.matches(Float64List.fromList(v), 4), isFalse);
          }
          expect(
            d32.matches(Float32List.fromList([1.5, 2.5, z, 3.5]), 4),
            isTrue,
          );
          expect(
            d64.matches(Float64List.fromList([1.5, 2.5, z, 3.5]), 4),
            isTrue,
          );
        }
      });

      test('a short storage is a RangeError, not a wrong answer', () {
        final d32 = sofab.Float32ArrayDefault(const [1.5, 2.5]);
        final d64 = sofab.Float64ArrayDefault(const [1.5, 2.5]);
        expect(
          () => d32.matches(Float32List.fromList([1.5]), 2),
          throwsRangeError,
        );
        expect(
          () => d64.matches(Float64List.fromList([1.5]), 2),
          throwsRangeError,
        );
      });

      test('a default that holds a NaN is compared on raw patterns', () {
        final nanA = f64FromBits(0x7FF8000000000001);
        final nanB = f64FromBits(0x7FF8000000000002);
        final d64 = sofab.Float64ArrayDefault([1.0, nanA, 0.0]);
        expect(d64.matches(Float64List.fromList([1.0, nanA, 0.0]), 3), isTrue);
        expect(d64.matches(Float64List.fromList([1.0, nanB, 0.0]), 3), isFalse);
        expect(
          d64.matches(Float64List.fromList([1.0, nanA, -0.0]), 3),
          isFalse,
        );
        expect(d64.matches(Float64List.fromList([1.0, 2.0, 0.0]), 3), isFalse);
        expect(
          d64.matches(Float64List.fromList([1.0, nanA, 0.0, 9.0]), 3),
          isTrue,
        );
        // a signaling fp32 NaN is compared as stored, not as the quieted double
        final d32 = sofab.Float32ArrayDefault(
          f32Bits([0x7F800001, 0x3FC00000]),
        );
        expect(d32.matches(f32Bits([0x7F800001, 0x3FC00000]), 2), isTrue);
        expect(d32.matches(f32Bits([0x7FC00001, 0x3FC00000]), 2), isFalse);
        expect(d32.matches(f32Bits([0x7F800001, 0x3FC00001]), 2), isFalse);
      });

      test('an empty default matches only the empty prefix', () {
        final d32 = sofab.Float32ArrayDefault(const []);
        final d64 = sofab.Float64ArrayDefault(const []);
        expect(d32.matches(Float32List(3), 0), isTrue);
        expect(d64.matches(Float64List(3), 0), isTrue);
        expect(d32.matches(Float32List(3), 1), isFalse);
      });

      test('cross-check against a plain reference bit loop', () {
        var s = 0x1234567;
        int next() {
          s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
          return s;
        }

        final pool = <double>[
          0.0,
          -0.0,
          1.5,
          -1.5,
          double.infinity,
          double.negativeInfinity,
          double.nan,
          f64FromBits(0x7FF8000000000001),
          2.0,
        ];
        var equal = 0, unequal = 0;
        for (var iter = 0; iter < 4000; iter++) {
          final len = next() % 12;
          final wide = iter.isEven;
          final dv = List<double>.generate(
            len,
            (_) => pool[next() % pool.length],
          );
          final field = List<double>.of(dv);
          if (next() % 3 != 0 && len > 0) {
            field[next() % len] = pool[next() % pool.length];
          }
          final cap = len + next() % 3;
          while (field.length < cap) {
            field.add(pool[next() % pool.length]);
          }
          final n = (next() % 9 == 0) ? len + 1 : len;
          if (n > cap) continue;
          if (wide) {
            final d = sofab.Float64ArrayDefault(dv);
            final a = Float64List.fromList(field);
            final want = ref(a, n, d.list);
            want ? equal++ : unequal++;
            expect(d.matches(a, n), want, reason: 'f64 $dv $field $n');
          } else {
            final d = sofab.Float32ArrayDefault(dv);
            final a = Float32List.fromList(field);
            final want = ref(a, n, d.list);
            want ? equal++ : unequal++;
            expect(d.matches(a, n), want, reason: 'f32 $dv $field $n');
          }
        }
        expect(equal, greaterThan(100));
        expect(unequal, greaterThan(100));
      });
    },
  );

  group('cross-check against a plain reference bit loop', () {
    test('deterministic pseudo-random arrays, fp64 and fp32', () {
      var s = 0x2545F491;
      int next() {
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
        return s;
      }

      // Few distinct values so equal and near-equal pairs are common.
      final pool64 = <double>[
        0.0,
        -0.0,
        1.5,
        -1.5,
        double.infinity,
        double.negativeInfinity,
        double.nan,
        f64FromBits(0x7FF8000000000001),
        f64FromBits(1),
      ];
      final pool32 = <double>[
        0.0,
        -0.0,
        1.5,
        f32FromBits(0x7FC00001),
        f32FromBits(0x7FC00002),
        f32FromBits(1),
      ];
      var equal = 0, unequal = 0;
      for (var iter = 0; iter < 3000; iter++) {
        final len = next() % 70;
        final pool = iter.isEven ? pool64 : pool32;
        final a = List<double>.generate(len, (_) => pool[next() % pool.length]);
        final b = List<double>.of(a);
        if (next() % 3 != 0 && len > 0) {
          b[next() % len] = pool[next() % pool.length];
        }
        if (next() % 11 == 0) b.add(0.0);
        final want = ref64(a, b);
        want ? equal++ : unequal++;
        expect(sofab.floatBitsEqual(a, b), want, reason: 'plain $a $b');
        if (iter.isEven) {
          expect(
            sofab.floatBitsEqual(
              Float64List.fromList(a),
              Float64List.fromList(b),
            ),
            want,
          );
        } else {
          // Through fp32 storage the narrowing may merge two distinct fp64
          // inputs, so the reference runs on what the lists actually hold.
          final fa = Float32List.fromList(a), fb = Float32List.fromList(b);
          expect(sofab.floatBitsEqual(fa, fb), ref64(fa, fb));
        }
      }
      expect(equal, greaterThan(100));
      expect(unequal, greaterThan(100));
    });
  });
}
