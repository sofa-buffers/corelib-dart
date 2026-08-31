import 'dart:typed_data';

import 'decoder.dart';
import 'utf8.dart';
import 'visitor_base.dart';
import 'wire.dart';

// The element collectors a schema-bound (generated) consumer needs for a
// WRAPPER array — an array whose elements are strings, blobs, messages, or
// further arrays, and which therefore travels as a sequence rather than as one
// of the compact array wire types (MESSAGE_SPEC §4.9) — plus the matrix
// collectors, whose elements are compact arrays.
//
// None of them carries schema knowledge: the destination, the declared
// capacity, the declared element `maxlen`, the declared row `count`, the
// receiver's own caps and, where an element is itself an object, the factory
// that makes one all arrive as constructor arguments. The code is the same
// shape for every schema, so it is written once here rather than emitted into
// every generated module.
//
// **These are not the codec** (CORELIB_PLAN §6.6.1). They ship in this
// repository so the generator need not emit them, but they are the *generated
// layer's* code: the codec never calls one directly — it calls the visitor, and
// the visitor is one of these. That is why they may allocate the container a
// wrapper array grows into, while the codec beside them allocates no payload
// storage at all (§6.6).
//
// **Every bound they apply is a number the caller passed in** (§6.2.1: *"The
// numbers and the allocation are not the codec's. The limits come from
// generated code, which knows the schema and the target"*). Two kinds of number
// sit side by side, and they are never both in play for one field:
//
// * a **schema** bound — `cap` (the declared `count:`), `emax` (the declared
//   element `maxlen:`), `rowCount` (a matrix row's declared `count:`). Negative
//   means the schema declared none. A breach is `INVALID` (MESSAGE_SPEC §7.1),
//   reported through [MessageVisitor.invalidate].
// * a **receiver** cap — `rcap`, `relemMax`, `rowCap` — consulted *only* where
//   its schema sibling is negative. A breach is a policy rejection:
//   `LimitExceeded`, never `INVALID` (§6.2.1, §6.3), reported through
//   [MessageVisitor.limitExceeded].
//
// The receiver caps are **required constructor arguments**: §6.2.1 admits
// *"no unset state and no unlimited mode"*, and the number is a per-deployment
// judgement this library is in no position to make. Nothing here supplies one
// that was not given: a cap that is not a usable positive number, on a field
// whose schema declared no bound, is a **caller defect** and is reported as
// such — [SofabError.invalidArgument] (§6.3), thrown from the constructor by
// [_requireCap]. It is deliberately *not* [MessageVisitor.limitExceeded]
// (which would promise a limit to raise that was never configured), and
// deliberately not the format ceiling: §6.2.1 is explicit that *"a format
// ceiling (§6.2) reached because no cap was stated is the format's bound, not
// a receiver cap, and a port MUST NOT present it as one"*. A caller that
// genuinely wants a ceiling as its policy may still pass [arrayMax] /
// [fixlenMax] — then the number is the caller's, which is the whole point.
//
// Each rule has exactly ONE implementation, [_overCapacity] for an index and
// [_overLength] for a count or a byte length, however many places state it
// (§6.2.1: *"The rule that applies it MUST have one implementation whichever
// way it was stated"*).

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

/// The length twin of [_overCapacity]: whether `n` — a payload's byte length or
/// a matrix row's element count — is past the bound that governs it.
///
/// Same split, same exclusivity, same categories. `max` is the schema's number
/// (negative: the schema declared none) and `rmax` the receiver's, consulted
/// only where the schema declared nothing. Checked at the length/count
/// **header**, before the payload the number sizes (§6.2.1).
bool _overLength(VisitorBase v, int n, int max, int rmax) {
  if (max >= 0) {
    if (n > max) {
      v.invalidate();
      return true;
    }
    return false;
  }
  if (n > rmax) {
    v.limitExceeded();
    return true;
  }
  return false;
}

/// Checks a receiver cap at construction and returns it unchanged.
///
/// `bound` is the schema sibling this cap stands in for (`cap`/`emax`/
/// `rowCount`). Where the schema declared a bound (`bound >= 0`) the cap is
/// never consulted (§6.2.1: a receiver cap *"MUST NOT be applied to a field the
/// schema already bounds"*), so its value is not this library's business and it
/// is passed through untouched.
///
/// Where the schema declared none, the cap is the *only* thing standing between
/// a sender and this receiver's allocation, and §6.2.1 leaves nothing to put
/// there on the caller's behalf: a codec *"MUST NOT supply a default for one it
/// was not given, MUST NOT read an omitted argument as unlimited, and MUST NOT
/// clamp to one"*, and a format ceiling reached because no cap was stated *"is
/// the format's bound, not a receiver cap"*. A non-positive number is therefore
/// a mistake in the **call**, reported in §6.3's `InvalidArgument` category —
/// not `LimitExceeded`, which would promise a limit to raise that was never
/// configured, and not `InvalidMessage`, since no message is involved yet.
///
/// Checking once here rather than per element keeps the guards a single
/// compare, and reports the defect before a byte is decoded.
int _requireCap(int rcap, int bound, String what) {
  if (bound >= 0) return rcap;
  if (rcap <= 0) {
    throw SofabException(
      SofabError.invalidArgument,
      '$what: a schema-unbounded field needs a positive receiver cap from '
      'generated code (CORELIB_PLAN 6.2.1); got $rcap',
    );
  }
  return rcap;
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
/// the declared element `maxlen` (or -1); `rcap` and `relemMax` are the
/// receiver's caps on the same two numbers, used only where the schema declared
/// none. All four are checked at the fixlen header, before the payload arrives
/// and before the destination is sized, so a message truncated right behind an
/// out-of-bound element is still INVALID rather than INCOMPLETE (§5.2).
///
/// The payload's UTF-8 is validated here because here is where the element is
/// **materialized**; a skipped payload never reaches a collector at all (§6.4).
class StringSeq extends VisitorBase {
  StringSeq(
    this.out,
    this.cap,
    this.emax, {
    required int rcap,
    required int relemMax,
  }) : rcap = _requireCap(rcap, cap, 'StringSeq.rcap'),
       relemMax = _requireCap(relemMax, emax, 'StringSeq.relemMax');

  final List<String> out;

  /// The schema `count:` — the element index bound (-1: none declared).
  final int cap;

  /// The **receiver cap** on the element index, used only where the schema
  /// declared no `count` (`cap < 0`) — see [_overCapacity]. Generated code
  /// passes the deployment's number; §6.2.1 gives this library none to invent,
  /// so it is required, and where it governs it must be positive — see
  /// [_requireCap].
  final int rcap;

  /// The schema element `maxlen:` — the element byte-length bound (-1: none).
  final int emax;

  /// The **receiver cap** on an element's byte length, used only where the
  /// schema declared no `maxlen` (`emax < 0`) — see [_overLength]. Required,
  /// and positive where it governs, for the reason [rcap] is.
  final int relemMax;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    // A contradicting subtype is not this array's element (§7.3): it is skipped,
    // so neither bound must be applied to it.
    if (subtype != FixlenType.string) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _overLength(this, length, emax, relemMax);
  }

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (_overCapacity(this, id, cap, rcap)) return;
    // A backstop, and coverage says so: [onFixlenHeader] already rejected these
    // bounds at the length word and [invalidate]/[limitExceeded] stopped the
    // decode there, so neither engine can reach it. It stays for a caller
    // driving the collector by hand, and because a guard that reads the
    // payload's own length is the one that cannot be wrong.
    if (_overLength(this, bytes.length, emax, relemMax)) return;
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
  BlobSeq(
    this.out,
    this.cap,
    this.emax, {
    required int rcap,
    required int relemMax,
  }) : rcap = _requireCap(rcap, cap, 'BlobSeq.rcap'),
       relemMax = _requireCap(relemMax, emax, 'BlobSeq.relemMax');

  final List<Uint8List> out;

  /// The schema `count:` — the element index bound (-1: none declared).
  final int cap;

  /// The **receiver cap** on the element index — see [StringSeq.rcap].
  final int rcap;

  /// The schema element `maxlen:` — the element byte-length bound (-1: none).
  final int emax;

  /// The **receiver cap** on an element's byte length — see
  /// [StringSeq.relemMax].
  final int relemMax;

  @override
  void onFixlenHeader(int id, int subtype, int length) {
    if (subtype != FixlenType.blob) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _overLength(this, length, emax, relemMax);
  }

  @override
  void onBlob(int id, Uint8List value) {
    if (_overCapacity(this, id, cap, rcap)) return;
    // The same backstop as StringSeq's, unreachable for the same reason.
    if (_overLength(this, value.length, emax, relemMax)) return;
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
  MessageSeq(this.out, this.cap, this.make, this.vis, {required int rcap})
    : rcap = _requireCap(rcap, cap, 'MessageSeq.rcap');

  final List<T> out;

  /// The schema `count:` — the element index bound (-1: none declared).
  final int cap;

  /// The **receiver cap** on the element index — see [StringSeq.rcap].
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
/// [NestedSeq] — the recursion the depth-3 shapes need. The row's own bounds,
/// schema and receiver alike, are the row collector's; this one bounds the row
/// **index** only.
class NestedSeq<T> extends VisitorBase {
  NestedSeq(this.out, this.cap, this.make, {required int rcap})
    : rcap = _requireCap(rcap, cap, 'NestedSeq.rcap');

  final List<List<T>> out;

  /// The schema `count:` — the row index bound (-1: none declared).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
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
///
/// A row here is a real compact array with a real `element_count` on the wire,
/// so it carries a second pair of bounds beside the row index: `rowCount`, the
/// row's declared `count:`, and `rowCap`, the receiver's cap where the schema
/// declared none. They are weighed in [onArrayBegin] — at the count word,
/// before the row's destination is sized (§6.2.1).
class IntMatrixSeq extends VisitorBase {
  IntMatrixSeq(
    this.out,
    this.cap,
    this.signed,
    this.lo,
    this.hi, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'IntMatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'IntMatrixSeq.rowCap');

  final List<List<int>> out;

  /// The schema `count:` of the matrix — the row index bound (-1: none).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;

  /// The schema `count:` of a **row** — its element count bound (-1: none).
  final int rowCount;

  /// The **receiver cap** on a row's element count, used only where the schema
  /// declared no row `count` (`rowCount < 0`). Required, and positive where it
  /// governs, for the reason [rcap] is.
  final int rowCap;

  final bool signed;
  final int lo;
  final int hi;

  ArrayKind get _kind => signed ? ArrayKind.signed : ArrayKind.unsigned;

  @override
  void onArrayBegin(int id, ArrayKind kind, int count) {
    // A row of the other kind is not this array's element (§7.3): skipped, so
    // no bound of this field's applies to it.
    if (kind != _kind) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _overLength(this, count, rowCount, rowCap);
  }

  void _row(int id, Int64List v) {
    if (_overCapacity(this, id, cap, rcap)) return;
    // The backstop to [onArrayBegin]'s row-count guard, reachable only by a
    // caller driving the collector by hand — see [StringSeq.onStringBytes].
    if (_overLength(this, v.length, rowCount, rowCap)) return;
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
///
/// `rowCount`/`rowCap` bound a row's element count exactly as [IntMatrixSeq]'s
/// do.
class DoubleMatrixSeq extends VisitorBase {
  DoubleMatrixSeq(
    this.out,
    this.cap,
    this.f64, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'DoubleMatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'DoubleMatrixSeq.rowCap');

  final List<List<double>> out;

  /// The schema `count:` of the matrix — the row index bound (-1: none).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;

  /// The schema `count:` of a **row** — its element count bound (-1: none).
  final int rowCount;

  /// The **receiver cap** on a row's element count — see [IntMatrixSeq.rowCap].
  final int rowCap;

  final bool f64;

  ArrayKind get _kind => f64 ? ArrayKind.fp64 : ArrayKind.fp32;

  @override
  void onArrayBegin(int id, ArrayKind kind, int count) {
    if (kind != _kind) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _overLength(this, count, rowCount, rowCap);
  }

  @override
  void onFp32Array(int id, Float32List values) {
    if (f64) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    if (_overLength(this, values.length, rowCount, rowCap)) return;
    _reserve(out, id, () => <double>[]);
    out[id] = copyFp32(values, values.length);
  }

  @override
  void onFp64Array(int id, Float64List values) {
    if (!f64) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    if (_overLength(this, values.length, rowCount, rowCap)) return;
    _reserve(out, id, () => <double>[]);
    out[id] = List<double>.from(values);
  }
}

/// Collects the rows of a boolean matrix. Booleans travel as the unsigned
/// integer wire type, so a row arrives on [onUnsignedArray] and any non-zero
/// element is `true`.
///
/// `rowCount`/`rowCap` bound a row's element count exactly as [IntMatrixSeq]'s
/// do.
class BoolMatrixSeq extends VisitorBase {
  BoolMatrixSeq(
    this.out,
    this.cap, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'BoolMatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'BoolMatrixSeq.rowCap');

  final List<List<bool>> out;

  /// The schema `count:` of the matrix — the row index bound (-1: none).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;

  /// The schema `count:` of a **row** — its element count bound (-1: none).
  final int rowCount;

  /// The **receiver cap** on a row's element count — see [IntMatrixSeq.rowCap].
  final int rowCap;

  @override
  void onArrayBegin(int id, ArrayKind kind, int count) {
    if (kind != ArrayKind.unsigned) return;
    if (_overCapacity(this, id, cap, rcap)) return;
    _overLength(this, count, rowCount, rowCap);
  }

  @override
  void onUnsignedArray(int id, Int64List values) {
    if (_overCapacity(this, id, cap, rcap)) return;
    if (_overLength(this, values.length, rowCount, rowCap)) return;
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
