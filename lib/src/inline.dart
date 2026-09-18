import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'decoder.dart' show ElemRange;
import 'utf8.dart';
import 'wire.dart';

// The decode destinations: storage of a fixed **capacity** plus a logical
// **length** — the Dart counterpart of corelib-c-cpp's `InlineVector<T, N>`,
// `FixedString<N>` and `FixedBytes<N>`.
//
// A Dart typed list has one length and no capacity: it can neither be resized
// nor told that only its first n elements are in use. A receiver that sizes its
// storage once, to the schema's maximum, and reuses it for every message
// therefore needs the used length carried *beside* the list — which is all
// these classes are. The codec binds one at the field header, sets [length] to
// the announced count there (as `readArray` calls `resize` in C++), and writes
// the payload straight into [storage]. Nothing is copied, no view is built and
// nothing is delivered afterwards: once `feed`/`decode` reports
// `DecodeStatus.complete`, every bound destination holds its field.
//
// They are the caller's storage, not the codec's (CORELIB_PLAN §6.6.1): the
// codec never allocates one, never grows one, and refuses one whose capacity
// is short of the announced count with `SofabError.invalidArgument` (§6.3).
// [ensureCapacity] exists for a visitor whose schema bounds nothing — it
// grows the storage *itself*, after checking the count against its own cap.
//
// Element access does not re-check [length]: the storage's own bounds check
// keeps it memory-safe, and a second compare against [length] measured 5 %
// on a 64-element array. Reading past [length] (but within [capacity]) yields
// whatever an earlier message left there.
//
// All five are `final`/`base` classes on purpose: a destination is read on the
// codec's hot path, and a single concrete type per field kind is what lets AOT
// inline every access to it.

/// A destination for an **integer array** field (`arrayUnsigned` or
/// `arraySigned`) — 64-bit elements, which is what both wire types decode to
/// (the declared element width is a schema matter, §4.7).
final class InlineInt64Array {
  /// Storage for [capacity] elements, empty.
  ///
  /// [range] is the field's declared element width (MESSAGE_SPEC §7.1); the
  /// codec applies it to every element as it is decoded and reports an element
  /// outside it as `INVALID`. `null` when the field declares nothing narrower
  /// than 64 bits.
  InlineInt64Array(int capacity, {this.range}) : storage = Int64List(capacity);

  /// A copy of [values], [length] set to match — the on-ramp for encoding.
  InlineInt64Array.of(List<int> values, {this.range})
    : storage = Int64List.fromList(values),
      length = values.length;

  /// The elements; the first [length] are in use.
  Int64List storage;

  /// The number of elements in use.
  int length = 0;

  /// The declared element width, or `null` for none.
  final ElemRange? range;

  /// How many elements [storage] holds.
  int get capacity => storage.length;

  @pragma('vm:prefer-inline')
  int operator [](int i) => storage[i];

  @pragma('vm:prefer-inline')
  void operator []=(int i, int value) => storage[i] = value;

  /// Grows [storage] to hold at least [n] elements, keeping the first [length].
  void ensureCapacity(int n) {
    if (n <= storage.length) return;
    storage = Int64List(n)..setRange(0, length, storage);
  }

  /// Replaces the contents with [values], growing [storage] if it must.
  void assign(List<int> values) {
    final n = values.length;
    if (n > storage.length) storage = Int64List(n);
    storage.setRange(0, n, values);
    length = n;
  }

  /// The elements in use, copied into a new growable list.
  List<int> toList() => List<int>.generate(length, (i) => storage[i]);
}

/// A destination for an **fp32 array** field.
///
/// [storage] holds the raw 32-bit patterns, so a signaling or payload NaN
/// survives bit-for-bit (§4.6) — as long as it is read back through a typed
/// list, not widened element by element into a Dart `double`.
final class InlineFloat32Array {
  /// Storage for [capacity] elements, empty.
  InlineFloat32Array(int capacity) : _storage = Float32List(capacity);

  /// A copy of [values], [length] set to match.
  InlineFloat32Array.of(List<double> values)
    : _storage = Float32List.fromList(values),
      length = values.length;

  Float32List _storage;
  Uint8List? _bytes;

  /// The elements; the first [length] are in use.
  Float32List get storage => _storage;
  set storage(Float32List value) {
    _storage = value;
    _bytes = null;
  }

  /// The number of elements in use.
  int length = 0;

  /// How many elements [storage] holds.
  int get capacity => _storage.length;

  /// [storage] as bytes — the view the codec copies the wire payload into,
  /// built once per storage rather than once per array (a typed-data view
  /// costs ~200 instructions under AOT).
  Uint8List get byteView => _bytes ??= Uint8List.view(
    _storage.buffer,
    _storage.offsetInBytes,
    _storage.lengthInBytes,
  );

  @pragma('vm:prefer-inline')
  double operator [](int i) => _storage[i];

  @pragma('vm:prefer-inline')
  void operator []=(int i, double value) => _storage[i] = value;

  /// Grows [storage] to hold at least [n] elements, keeping the first [length]
  /// bit-exact.
  void ensureCapacity(int n) {
    if (n <= _storage.length) return;
    storage = Float32List(n)..setRange(0, length, _storage);
  }

  /// Replaces the contents with [values], growing [storage] if it must.
  void assign(List<double> values) {
    final n = values.length;
    if (n > _storage.length) storage = Float32List(n);
    _storage.setRange(0, n, values);
    length = n;
  }

  /// The elements in use, widened into a new growable list (a NaN's payload is
  /// not preserved by the widening — read [storage] for that).
  List<double> toList() => List<double>.generate(length, (i) => _storage[i]);
}

/// A destination for an **fp64 array** field.
final class InlineFloat64Array {
  /// Storage for [capacity] elements, empty.
  InlineFloat64Array(int capacity) : _storage = Float64List(capacity);

  /// A copy of [values], [length] set to match.
  InlineFloat64Array.of(List<double> values)
    : _storage = Float64List.fromList(values),
      length = values.length;

  Float64List _storage;
  Uint8List? _bytes;

  /// The elements; the first [length] are in use.
  Float64List get storage => _storage;
  set storage(Float64List value) {
    _storage = value;
    _bytes = null;
  }

  /// The number of elements in use.
  int length = 0;

  /// How many elements [storage] holds.
  int get capacity => _storage.length;

  /// [storage] as bytes — see [InlineFloat32Array.byteView].
  Uint8List get byteView => _bytes ??= Uint8List.view(
    _storage.buffer,
    _storage.offsetInBytes,
    _storage.lengthInBytes,
  );

  @pragma('vm:prefer-inline')
  double operator [](int i) => _storage[i];

  @pragma('vm:prefer-inline')
  void operator []=(int i, double value) => _storage[i] = value;

  /// Grows [storage] to hold at least [n] elements, keeping the first [length].
  void ensureCapacity(int n) {
    if (n <= _storage.length) return;
    storage = Float64List(n)..setRange(0, length, _storage);
  }

  /// Replaces the contents with [values], growing [storage] if it must.
  void assign(List<double> values) {
    final n = values.length;
    if (n > _storage.length) storage = Float64List(n);
    _storage.setRange(0, n, values);
    length = n;
  }

  /// The elements in use, copied into a new growable list.
  List<double> toList() => List<double>.generate(length, (i) => _storage[i]);
}

/// A destination for a **blob** field — and, through [InlineString], for a
/// `string`.
base class InlineBytes {
  /// Storage for [capacity] bytes, empty.
  InlineBytes(int capacity) : storage = Uint8List(capacity);

  /// A copy of [bytes], [length] set to match.
  InlineBytes.of(List<int> bytes)
    : storage = Uint8List.fromList(bytes),
      length = bytes.length;

  /// The bytes; the first [length] are in use.
  Uint8List storage;

  /// The number of bytes in use.
  int length = 0;

  /// How many bytes [storage] holds.
  int get capacity => storage.length;

  /// Grows [storage] to hold at least [n] bytes, keeping the first [length].
  void ensureCapacity(int n) {
    if (n <= storage.length) return;
    storage = Uint8List(n)..setRange(0, length, storage);
  }

  /// Replaces the contents with [bytes], growing [storage] if it must.
  void assign(List<int> bytes) {
    final n = bytes.length;
    if (n > storage.length) storage = Uint8List(n);
    storage.setRange(0, n, bytes);
    length = n;
  }

  /// The bytes in use, copied into a new list.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(storage, 0, length));
}

/// A destination for a **string** field: its UTF-8 bytes.
///
/// The codec validates a bound string's bytes once the payload is whole and
/// reports invalid UTF-8 as `INVALID` (CORELIB_PLAN §6.4) — a skipped string is
/// never inspected. The Dart `String` is built only when asked for, by
/// [toString].
final class InlineString extends InlineBytes {
  /// Storage for [capacity] bytes, empty.
  InlineString(super.capacity);

  /// [value] encoded as UTF-8, [length] set to match. Throws
  /// [SofabError.invalidArgument] for an unpaired surrogate, which has no UTF-8
  /// encoding.
  InlineString.of(String value) : super(0) {
    assignString(value);
  }

  /// Replaces the contents with [value] encoded as UTF-8, growing [storage] if
  /// it must. Throws [SofabError.invalidArgument] for an unpaired surrogate.
  void assignString(String value) {
    final bytes = encodeUtf8Strict(value);
    if (bytes == null) {
      throw const SofabException(
        SofabError.invalidArgument,
        'string is not valid UTF-8 (unpaired surrogate)',
      );
    }
    assign(bytes);
  }

  /// The string in use, decoded. An all-ASCII payload skips the UTF-8 decoder.
  @override
  String toString() {
    final s = storage;
    final n = length;
    var i = 0;
    while (i < n && s[i] < 0x80) {
      i++;
    }
    if (i == n) return String.fromCharCodes(s, 0, n);
    return utf8.decoder.convert(s, 0, n);
  }
}
