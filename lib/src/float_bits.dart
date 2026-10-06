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
/// of a field against an array. A generated class, whose default is a constant,
/// holds it in a [Float32ArrayDefault] / [Float64ArrayDefault] instead, which
/// answers the same question faster.
///
/// The length is compared first and a mismatch returns without reading an
/// element. No allocation beyond two typed-list views, no mutation.
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
  if (n != b.length) return false;
  if (n == 0) return true;
  if (a is Float32List && b is Float32List) {
    final x = Uint32List.view(a.buffer, a.offsetInBytes, n);
    final y = Uint32List.view(b.buffer, b.offsetInBytes, n);
    for (var i = 0; i < n; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }
  if (a is Float64List && b is Float64List) {
    final x = Int64List.view(a.buffer, a.offsetInBytes, n);
    final y = Int64List.view(b.buffer, b.offsetInBytes, n);
    for (var i = 0; i < n; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }
  for (var i = 0; i < n; i++) {
    _f64[0] = a[i];
    final p = _i64[0];
    _f64[0] = b[i];
    if (p != _i64[0]) return false;
  }
  return true;
}

/// The declared default of an fp32 array field, prepared once so that the test
/// "does this field still equal its default" costs a plain element loop.
///
/// A generated class holds one per defaulted field in a `static final`, fills
/// the field's storage from [list] (`InlineFloat32Array.assign`) and asks
/// [matches] on every encode (MESSAGE_SPEC §2, §5.1: a field is written only
/// when it differs from its default).
///
/// [matches] is [floatBitsEqual] on the field's first `length` elements against
/// [list], bit for bit: `+0.0` differs from `-0.0`, a NaN equals a NaN of
/// identical bits, the length is compared first. What makes it cheap is that the
/// default is a constant. Two doubles that compare `==` have the same bits unless
/// both are zero, and which indices of the default are zero is known here, once.
/// So [matches] runs one `!=` loop over the elements (a NaN in the field is a
/// mismatch, since the default holds none), split at the first zero index: the
/// element there is read once, by the loop, and its sign tested on the spot.
/// Further zeros, and a default that holds a NaN (whose `!=` always fails), are
/// the rare cases and are settled out of line.
final class Float32ArrayDefault {
  /// A typed copy of [values] with the zero and NaN positions noted.
  Float32ArrayDefault(List<double> values)
    : this._(Float32List.fromList(values));

  Float32ArrayDefault._(this.list)
    : _hasNaN = _anyNaN(list),
      _split = _firstZero(list) < 0 ? list.length : _firstZero(list),
      _splitNeg = _firstZero(list) >= 0 && list[_firstZero(list)].isNegative,
      _zeroRest = _otherZeros(list),
      _moreZeros = _otherZeros(list).isNotEmpty;

  /// The default itself, for filling a field's storage.
  final Float32List list;
  final bool _hasNaN;
  final int _split; // index of the first zero element, the length when none
  final bool _splitNeg; // that zero is -0.0
  final Uint32List _zeroRest; // the other zeros: index * 2, plus 1 for -0.0
  final bool _moreZeros; // _zeroRest is not empty

  /// Whether the first [n] elements of [a] are, bit for bit, this default.
  /// [n] must not exceed `a.length` (an index past it throws, as on any typed
  /// list). A length mismatch reads no element; there is no allocation, and no
  /// mutation, unless the default holds a NaN.
  @pragma('vm:prefer-inline')
  bool matches(Float32List a, int n) {
    final b = list;
    if (n != b.length) return false;
    final z = _split;
    var i = 0;
    for (; i < z; i++) {
      if (a[i] != b[i]) return _hasNaN && _exactBits(a, b, n);
    }
    if (z == n) return true;
    final x = a[z];
    if (x != 0 || x.isNegative != _splitNeg) {
      return _hasNaN && _exactBits(a, b, n);
    }
    for (i = z + 1; i < n; i++) {
      if (a[i] != b[i]) return _hasNaN && _exactBits(a, b, n);
    }
    return !_moreZeros || _restSignsMatch(a, _zeroRest);
  }
}

/// [Float32ArrayDefault] for an fp64 array field: `Float64List`s, 64-bit
/// patterns.
final class Float64ArrayDefault {
  /// A typed copy of [values] with the zero and NaN positions noted.
  Float64ArrayDefault(List<double> values)
    : this._(Float64List.fromList(values));

  Float64ArrayDefault._(this.list)
    : _hasNaN = _anyNaN(list),
      _split = _firstZero(list) < 0 ? list.length : _firstZero(list),
      _splitNeg = _firstZero(list) >= 0 && list[_firstZero(list)].isNegative,
      _zeroRest = _otherZeros(list),
      _moreZeros = _otherZeros(list).isNotEmpty;

  /// The default itself, for filling a field's storage.
  final Float64List list;
  final bool _hasNaN;
  final int _split; // index of the first zero element, the length when none
  final bool _splitNeg; // that zero is -0.0
  final Uint32List _zeroRest; // the other zeros: index * 2, plus 1 for -0.0
  final bool _moreZeros; // _zeroRest is not empty

  /// Whether the first [n] elements of [a] are, bit for bit, this default; see
  /// [Float32ArrayDefault.matches].
  @pragma('vm:prefer-inline')
  bool matches(Float64List a, int n) {
    final b = list;
    if (n != b.length) return false;
    final z = _split;
    var i = 0;
    for (; i < z; i++) {
      if (a[i] != b[i]) return _hasNaN && _exactBits(a, b, n);
    }
    if (z == n) return true;
    final x = a[z];
    if (x != 0 || x.isNegative != _splitNeg) {
      return _hasNaN && _exactBits(a, b, n);
    }
    for (i = z + 1; i < n; i++) {
      if (a[i] != b[i]) return _hasNaN && _exactBits(a, b, n);
    }
    return !_moreZeros || _restSignsMatch(a, _zeroRest);
  }
}

bool _anyNaN(List<double> v) {
  for (var i = 0; i < v.length; i++) {
    if (v[i].isNaN) return true;
  }
  return false;
}

int _firstZero(List<double> v) {
  for (var i = 0; i < v.length; i++) {
    if (v[i] == 0) return i;
  }
  return -1;
}

// Every zero after the first, as index * 2 plus 1 for a -0.0.
Uint32List _otherZeros(List<double> v) {
  final out = <int>[];
  for (var i = _firstZero(v) + 1; i > 0 && i < v.length; i++) {
    if (v[i] == 0) out.add(i * 2 + (v[i].isNegative ? 1 : 0));
  }
  return Uint32List.fromList(out);
}

// The signs at a default's zeros after the first: out of line, so matches()
// stays small for the common defaults. Each entry is index * 2, plus 1 for -0.0;
// the elements there already compared equal to zero.
@pragma('vm:never-inline')
bool _restSignsMatch(List<double> a, Uint32List rest) {
  for (var k = 0; k < rest.length; k++) {
    final e = rest[k];
    if (a[e >> 1].isNegative != ((e & 1) != 0)) return false;
  }
  return true;
}

// The first n elements of a against b on raw patterns, through typed views (a
// view costs an allocation): the path of a default that holds a NaN.
bool _exactBits(List<double> a, List<double> b, int n) {
  if (n == 0) return true;
  if (a is Float32List && b is Float32List) {
    final x = Uint32List.view(a.buffer, a.offsetInBytes, n);
    final y = Uint32List.view(b.buffer, b.offsetInBytes, n);
    for (var i = 0; i < n; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }
  final x = Int64List.view((a as Float64List).buffer, a.offsetInBytes, n);
  final y = Int64List.view((b as Float64List).buffer, b.offsetInBytes, n);
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
