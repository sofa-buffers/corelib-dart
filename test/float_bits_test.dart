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

  group('float32BitsEqual / float64BitsEqual (the generated default test)', () {
    Float32List l32(List<int> bits) =>
        Float32List.view(Uint32List.fromList(bits).buffer);

    test(
      'the first n elements of a larger storage against a whole default',
      () {
        final def32 = Float32List.fromList([0.0, 1.5]);
        final def64 = Float64List.fromList([0.0, 1.5]);
        final s32 = Float32List.fromList([0.0, 1.5, 9, 9]);
        final s64 = Float64List.fromList([0.0, 1.5, 9, 9]);
        expect(sofab.float32BitsEqual(s32, 2, def32), isTrue);
        expect(sofab.float64BitsEqual(s64, 2, def64), isTrue);
        expect(sofab.float32BitsEqual(s32, 3, def32), isFalse);
        expect(sofab.float64BitsEqual(s64, 1, def64), isFalse);
        expect(sofab.float32BitsEqual(s32, 0, Float32List(0)), isTrue);
        expect(sofab.float64BitsEqual(s64, 0, Float64List(0)), isTrue);
      },
    );

    test('-0.0 against +0.0 at every index, in both directions', () {
      for (var i = 0; i < 3; i++) {
        final z = [0.0, 0.0, 0.0];
        final n = [0.0, 0.0, 0.0]..[i] = -0.0;
        expect(
          sofab.float32BitsEqual(
            Float32List.fromList(n),
            3,
            Float32List.fromList(z),
          ),
          isFalse,
        );
        expect(
          sofab.float32BitsEqual(
            Float32List.fromList(z),
            3,
            Float32List.fromList(n),
          ),
          isFalse,
        );
        expect(
          sofab.float64BitsEqual(
            Float64List.fromList(n),
            3,
            Float64List.fromList(z),
          ),
          isFalse,
        );
        expect(
          sofab.float64BitsEqual(
            Float64List.fromList(z),
            3,
            Float64List.fromList(n),
          ),
          isFalse,
        );
        expect(
          sofab.float64BitsEqual(
            Float64List.fromList(n),
            3,
            Float64List.fromList(n),
          ),
          isTrue,
        );
      }
    });

    test('equal nonzero values, and a mismatch, never trip the zero test', () {
      expect(
        sofab.float64BitsEqual(
          Float64List.fromList([-1.5, 2.0, double.infinity]),
          3,
          Float64List.fromList([-1.5, 2.0, double.infinity]),
        ),
        isTrue,
      );
      expect(
        sofab.float32BitsEqual(
          Float32List.fromList([1.0, 2.0]),
          2,
          Float32List.fromList([1.0, 3.0]),
        ),
        isFalse,
      );
      // a NaN against a number, either way round, is a mismatch
      expect(
        sofab.float64BitsEqual(
          Float64List.fromList([double.nan]),
          1,
          Float64List.fromList([1.0]),
        ),
        isFalse,
      );
      expect(
        sofab.float32BitsEqual(
          Float32List.fromList([1.0]),
          1,
          Float32List.fromList([double.nan]),
        ),
        isFalse,
      );
    });

    test('a NaN pair is decided on the whole prefix, patterns and all', () {
      expect(
        sofab.float32BitsEqual(l32([0x7FC00001, 7]), 1, l32([0x7FC00001])),
        isTrue,
      );
      expect(
        sofab.float32BitsEqual(l32([0x7FC00001]), 1, l32([0x7FC00002])),
        isFalse,
      );
      expect(
        sofab.float32BitsEqual(l32([0x7F800001]), 1, l32([0x7FC00001])),
        isFalse,
      );
      // an element before the NaN pair already differs in its sign
      final a = Float32List.fromList([-0.0, double.nan]);
      final b = Float32List.fromList([0.0, double.nan]);
      expect(sofab.float32BitsEqual(a, 2, b), isFalse);
      final a64 = Float64List.fromList([1.0, f64FromBits(0x7FF8000000000001)]);
      final b64 = Float64List.fromList([1.0, f64FromBits(0x7FF8000000000002)]);
      expect(sofab.float64BitsEqual(a64, 2, a64), isTrue);
      expect(sofab.float64BitsEqual(a64, 2, b64), isFalse);
    });

    test(
      'a length mismatch reads no element, a short storage is a RangeError',
      () {
        expect(
          sofab.float32BitsEqual(Float32List(2), 2, Float32List(3)),
          isFalse,
        );
        expect(
          sofab.float64BitsEqual(Float64List(2), 1, Float64List(0)),
          isFalse,
        );
        expect(
          () => sofab.float32BitsEqual(Float32List(1), 2, Float32List(2)),
          throwsRangeError,
        );
        expect(
          () => sofab.float64BitsEqual(Float64List(1), 2, Float64List(2)),
          throwsRangeError,
        );
      },
    );
  });

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
