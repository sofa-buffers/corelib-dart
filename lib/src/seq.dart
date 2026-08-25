import 'dart:typed_data';

import 'decoder.dart';
import 'utf8.dart';
import 'visitor_base.dart';
import 'wire.dart';

// The element collectors a schema-bound (generated) consumer needs for a
// WRAPPER array — an array whose elements are strings, blobs, messages, or
// further arrays, and which therefore travels as a sequence rather than as one
// of the compact array wire types (MESSAGE_SPEC §4.9).
//
// None of them carries schema knowledge: the destination, the declared
// capacity, the declared element `maxlen` and, where an element is itself an
// object, the factory that makes one all arrive as constructor arguments. The
// code is the same shape for every schema, so it is written once here rather
// than emitted into every generated module.
//
// What made that possible only recently is the verdict channel: an element past
// the declared capacity is INVALID (§5.1/§7.1) and a collector has to be able to
// say so. It calls [MessageVisitor.invalidate], which stops the decode where it
// stands. Before that channel existed these collectors had to take a flag from
// the generated layer, and a corelib type must not take a generated one as a
// parameter — which is why they stayed emitted until now.

/// Whether `id` is past the bound that governs this array, rejecting the decode
/// if so — **before** the container it indexes into is extended.
///
/// A wrapper array carries no count *header*: its elements are keyed by an
/// unbounded varint index and its length is *highest present id + 1*
/// (MESSAGE_SPEC §5.1). So the index **is** the length, and the index is what
/// has to be bounded. CORELIB_PLAN §6.2.1 says the same from the other side:
/// *"For a sequence array, whose length is not announced, that point is the
/// element **index**, checked before the container it indexes into is
/// extended."*
///
/// Which bound governs depends on the schema, and the two are never both in
/// play (§6.2.1: a receiver cap *"MUST NOT be applied to a field the schema
/// already bounds"*):
///
/// * `cap >= 0` — the schema declared a `count`. An index at or beyond it
///   contradicts the schema both peers agreed on, so it is `INVALID` (§7.1),
///   reported through [MessageVisitor.invalidate].
/// * `cap < 0` — the schema declared none, and the **receiver cap** `rcap`
///   governs instead. The bytes are well-formed and decode under a looser cap,
///   so the breach is a policy rejection: `LimitExceeded`, never `INVALID`
///   (§6.2.1, §6.3), reported through [MessageVisitor.limitExceeded].
bool _overCapacity(VisitorBase v, int id, int cap, int rcap) {
  if (cap >= 0) {
    if (id >= cap) {
      v.invalidate();
      return true;
    }
    return false;
  }
  if (id >= rcap) {
    v.limitExceeded();
    return true;
  }
  return false;
}

/// Grows `out` so that index `id` exists, filling the gap with `fill()`.
///
/// Gaps are ordinary: a conformant encoder omits an interior element equal to
/// the element default (§2), and only the last element is guaranteed present —
/// which is what makes the decoded length "highest present id + 1" exact.
///
/// Growth **geometry** is `List.add`'s: Dart's growable list doubles its
/// backing store, so filling a gap of *n* costs O(n) copies amortised rather
/// than O(n²) (CORELIB_PLAN §7.2 item 8). The language offers no allocation
/// counter to assert that from a test, which the README states rather than
/// reporting the case as covered.
void _reserve<T>(List<T> out, int id, T Function() fill) {
  while (out.length <= id) {
    out.add(fill());
  }
}

/// Collects the elements of a `string` wrapper array into `out`.
///
/// `cap` is the schema `count` (or -1 when the array is unbounded) and `emax`
/// the declared element `maxlen` (or -1). Both bounds are checked at the fixlen
/// header, before the payload arrives, so a message truncated right behind an
/// out-of-bound element is still INVALID rather than INCOMPLETE (§5.2).
///
/// The payload's UTF-8 is validated here because here is where the element is
/// **materialized**; a skipped payload never reaches a collector at all (§6.4).
class StringSeq extends VisitorBase {
  StringSeq(
    this.out,
    this.cap,
    this.emax, {
    this.rcap = defaultMaxDynArrayCount,
  });

  final List<String> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final int emax;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    // A contradicting subtype is not this array's element (§7.3): it is skipped,
    // so the capacity bound must not be applied to it either.
    if (subtype != FixlenType.string) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    if (emax >= 0 && length > emax) invalidate();
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (_overCapacity(this, id, cap, rcap)) return;
    // A backstop, and coverage says so: [onFixlenHeader] already rejected this
    // bound at the length word and [invalidate] stopped the decode there, so
    // neither engine can reach it. It stays for a caller driving the collector
    // by hand, and because a guard that reads the payload's own length is the
    // one that cannot be wrong.
    if (emax >= 0 && bytes.length > emax) {
      invalidate();
      return;
    }
    final s = decodeUtf8Strict(bytes);
    if (s == null) {
      invalidate();
      return;
    }
    _reserve(out, id, () => '');
    out[id] = s;
  }
}

/// Collects the elements of a `blob` wrapper array into `out`.
///
/// The bounds behave exactly as [StringSeq]'s. A blob is never validated as
/// text; the bytes are copied, so a decoded message outlives the buffer it was
/// decoded from.
class BlobSeq extends VisitorBase {
  BlobSeq(this.out, this.cap, this.emax, {this.rcap = defaultMaxDynArrayCount});

  final List<Uint8List> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final int emax;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (subtype != FixlenType.blob) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    if (emax >= 0 && length > emax) invalidate();
  }

  @override
  void onBlob(int id, Uint8List value) {
    if (_overCapacity(this, id, cap, rcap)) return;
    // The same backstop as StringSeq's, unreachable for the same reason.
    if (emax >= 0 && value.length > emax) {
      invalidate();
      return;
    }
    _reserve(out, id, () => Uint8List(0));
    out[id] = Uint8List.fromList(value);
  }
}

/// Collects the elements of a `struct`/`union` wrapper array into `out`.
///
/// `make` builds an element at its default and `vis` the visitor that fills one.
/// Both reach a generated type, and both do so as *arguments* — which is what
/// keeps this class schema-free: it never names one.
///
/// An element is filled in place at its id rather than appended, so a re-opened
/// element id merges into what an earlier opening set (§7.4).
class MessageSeq<T> extends VisitorBase {
  MessageSeq(
    this.out,
    this.cap,
    this.make,
    this.vis, {
    this.rcap = defaultMaxDynArrayCount,
  });

  final List<T> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final T Function() make;
  final MessageVisitor Function(T) vis;

  @override
  MessageVisitor? onSequenceStart(int id) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    _reserve(out, id, make);
    return vis(out[id]);
  }
}

/// Collects the rows of an array whose elements are themselves WRAPPER arrays.
///
/// `make` builds the collector for one row, which for a row of rows is another
/// [NestedSeq] — the recursion the depth-3 shapes need.
class NestedSeq<T> extends VisitorBase {
  NestedSeq(
    this.out,
    this.cap,
    this.make, {
    this.rcap = defaultMaxDynArrayCount,
  });

  final List<List<T>> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final MessageVisitor Function(List<T>) make;

  @override
  MessageVisitor? onSequenceStart(int id) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    _reserve(out, id, () => <T>[]);
    return make(out[id]);
  }
}

/// Collects the rows of an integer matrix — an array whose elements are compact
/// integer arrays, so each row arrives whole on one of the array callbacks.
///
/// `signed` selects which callback is this array's: a row arriving on the other
/// one contradicts the declared element type and is skipped (§7.3), not
/// rejected. `lo`/`hi` bound each element to its declared width (§7.1); equal
/// values mean "nothing narrower than the wire to check".
class IntMatrixSeq extends VisitorBase {
  IntMatrixSeq(
    this.out,
    this.cap,
    this.signed,
    this.lo,
    this.hi, {
    this.rcap = defaultMaxDynArrayCount,
  });

  final List<List<int>> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final bool signed;
  final int lo;
  final int hi;

  void _row(int id, Int64List v) {
    if (_overCapacity(this, id, cap, rcap)) return;
    if (lo != hi) {
      for (final e in v) {
        if (e < lo || e > hi) {
          invalidate();
          return;
        }
      }
    }
    _reserve(out, id, () => <int>[]);
    out[id] = List<int>.from(v);
  }

  @override
  void onUnsignedArray(int id, Int64List values) {
    if (!signed) _row(id, values);
  }

  @override
  void onSignedArray(int id, Int64List values) {
    if (signed) _row(id, values);
  }
}

/// Collects the rows of a floating-point matrix. `f64` selects which of the two
/// element kinds is this array's; the other is skipped (§7.3).
///
/// An fp32 row is copied through [copyFp32] rather than element by element, so a
/// signaling or payload NaN survives bit-for-bit (§4.6/§6.5) — widening each
/// element through a Dart `double` would quiet it.
class DoubleMatrixSeq extends VisitorBase {
  DoubleMatrixSeq(
    this.out,
    this.cap,
    this.f64, {
    this.rcap = defaultMaxDynArrayCount,
  });

  final List<List<double>> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;
  final bool f64;

  @override
  void onFp32Array(int id, Float32List values) {
    if (f64) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _reserve(out, id, () => <double>[]);
    out[id] = copyFp32(values, values.length);
  }

  @override
  void onFp64Array(int id, Float64List values) {
    if (!f64) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _reserve(out, id, () => <double>[]);
    out[id] = List<double>.from(values);
  }
}

/// Collects the rows of a boolean matrix. Booleans travel as the unsigned
/// integer wire type, so a row arrives on [onUnsignedArray] and any non-zero
/// element is `true`.
class BoolMatrixSeq extends VisitorBase {
  BoolMatrixSeq(this.out, this.cap, {this.rcap = defaultMaxDynArrayCount});

  final List<List<bool>> out;
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; the default is the family's
  /// [defaultMaxDynArrayCount], because §6.2.1 admits no unset state.
  final int rcap;

  @override
  void onUnsignedArray(int id, Int64List values) {
    if (_overCapacity(this, id, cap, rcap)) return;
    _reserve(out, id, () => <bool>[]);
    out[id] = [for (final v in values) v != 0];
  }
}

/// Bit-exact fp32 array copy into a fresh [Float32List] of length at least `n`.
///
/// A raw byte copy, not a per-element assignment: a signaling or payload NaN
/// read out of a `Float32List` into a Dart `double` is quieted by the widening,
/// and `writeFp32Array` re-emits a `Float32List`'s bytes verbatim — so the bits
/// have to survive the copy for a round trip to be bit-exact (§4.6/§6.5).
Float32List copyFp32(Float32List v, int n) {
  final out = Float32List(n < v.length ? v.length : n);
  Uint8List.sublistView(
    out,
  ).setRange(0, v.length * 4, Uint8List.sublistView(v));
  return out;
}
