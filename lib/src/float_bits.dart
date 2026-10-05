import 'dart:typed_data';

// Bit-pattern equality for float arrays, for the generated layer. Sparse
// omission (MESSAGE_SPEC §2, §5.1) writes a field only when it differs from
// its declared default, and floats round-trip bit for bit (CORELIB_PLAN §4.6):
// `[-0.0, 1.5]` is NOT the default `[0.0, 1.5]`. `elementsEqual` cannot say so
// for floats, because `==` on `double` is IEEE equality (`-0.0 == 0.0`,
// `NaN != NaN`). The comparison is the same for every schema, so it is written
// once here instead of being emitted into every generated file.

// One shared 8-byte cell: a double is stored through `_f64` and its 64-bit
// pattern read back through `_i64`. Statics are per isolate, so this is not
// shared state across threads.
final Float64List _f64 = Float64List(1);
final Int64List _i64 = _f64.buffer.asInt64List();

/// Whether [a] and [b] have the same length and the same IEEE-754 **bit
/// pattern** at every index.
///
/// There is no `==` on a `double` anywhere in it: `+0.0` and `-0.0` differ, two
/// NaNs are equal exactly when their patterns are identical (payload
/// included), and the infinities and subnormals compare as the bits they are.
///
/// [length], when given, is the number of leading elements of [a] that take
/// part, for a destination whose storage is sized to its capacity and whose
/// count is held beside it (`InlineFloat32Array.storage` and `.length`). It
/// must not exceed `a.length`. [b] is always taken whole, so the call
/// `floatBitsEqual(field.storage, b, length: field.length)` is the default test
/// of a field against its constant default array.
///
/// The length is compared first and a mismatch returns without reading an
/// element. No allocation unless a NaN pair is met, no mutation.
///
/// * Two `Float32List`s are compared on their 32-bit patterns, through
///   `Uint32List` views, so an fp32 signaling NaN is compared as stored and not
///   as the quieted `double` it widens to.
/// * Two `Float64List`s are compared on their 64-bit patterns, through
///   `Int64List` views.
/// * Any other combination (a plain `List<double>`, a `const` literal, or a
///   `Float32List` against a `Float64List`) compares the 64-bit pattern of the
///   `double` each element holds. For an fp32 value held as a double that is the
///   widened pattern, which distinguishes everything an fp32 can hold except
///   the quiet bit of a signaling NaN, which the widening may set. The fp32
///   signaling-NaN raw-bytes path (CORELIB_PLAN §6.5) is separate and does not
///   go through here.
bool floatBitsEqual(List<double> a, List<double> b, {int? length}) {
  final n = length ?? a.length;
  RangeError.checkValueInInterval(n, 0, a.length, 'length');
  if (a is Float32List && b is Float32List) return float32BitsEqual(a, n, b);
  if (a is Float64List && b is Float64List) return float64BitsEqual(a, n, b);
  if (n != b.length) return false;
  for (var i = 0; i < n; i++) {
    _f64[0] = a[i];
    final p = _i64[0];
    _f64[0] = b[i];
    if (p != _i64[0]) return false;
  }
  return true;
}

/// [floatBitsEqual] for the generated default test of an fp32 array field: the
/// first [n] elements of [a] against [b] taken whole. Both are `Float32List`s
/// (`InlineFloat32Array.storage` and its constant default), so there is no type
/// test, no optional parameter and no range check on the way in; [n] must not
/// exceed `a.length` (an index past it throws, as on any typed list). The
/// length is compared first and a mismatch reads no element.
///
/// Elements are compared as `double`s: equal values are equal bits except for
/// the two zeros. When both are zero, `x * y` is `-0.0` exactly when their signs
/// differ, so the sign is read from one product and no division or view is
/// needed. A pair of NaNs goes to the exact 32-bit pattern check, so a signaling NaN is
/// compared as stored. No allocation unless a NaN pair is met, no mutation.
@pragma('vm:prefer-inline')
bool float32BitsEqual(Float32List a, int n, Float32List b) {
  if (n != b.length) return false;
  for (var i = 0; i < b.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x == y) {
      if (x == 0 && (x * y).isNegative) return false;
    } else if (x == x || y == y) {
      return false;
    } else {
      return _nanPairEqual32(a, b, n);
    }
  }
  return true;
}

/// [float32BitsEqual] for an fp64 array field: `Float64List`s, compared on
/// their 64-bit patterns.
@pragma('vm:prefer-inline')
bool float64BitsEqual(Float64List a, int n, Float64List b) {
  if (n != b.length) return false;
  for (var i = 0; i < b.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x == y) {
      if (x == 0 && (x * y).isNegative) return false;
    } else if (x == x || y == y) {
      return false;
    } else {
      return _nanPairEqual64(a, b, n);
    }
  }
  return true;
}

// The slow path, reached only once a NaN pair has been met: the whole prefix on
// raw patterns, through typed views (a view costs an allocation).
bool _nanPairEqual32(Float32List a, Float32List b, int n) {
  final x = Uint32List.view(a.buffer, a.offsetInBytes, n);
  final y = Uint32List.view(b.buffer, b.offsetInBytes, n);
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

bool _nanPairEqual64(Float64List a, Float64List b, int n) {
  final x = Int64List.view(a.buffer, a.offsetInBytes, n);
  final y = Int64List.view(b.buffer, b.offsetInBytes, n);
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
