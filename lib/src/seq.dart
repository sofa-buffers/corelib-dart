import 'dart:typed_data';

import 'decoder.dart';
import 'inline.dart';
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
bool _overCapacity(MessageVisitor v, int id, int cap, int rcap) {
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
bool _overLength(MessageVisitor v, int n, int max, int rmax) {
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

/// Collects the elements of a `string` wrapper array into `out`.
///
/// `cap` is the schema `count` (or -1 when the array is unbounded) and `emax`
/// the declared element `maxlen` (or -1); `rcap` and `relemMax` are the
/// receiver's caps on the same two numbers, used only where the schema declared
/// none. All four are checked at the element's header, before its payload
/// arrives and before its storage is chosen, so a message truncated right
/// behind an out-of-bound element is still INVALID rather than INCOMPLETE
/// (§5.2).
///
/// Each element is decoded straight into its slot of `out` — grown with empty
/// strings up to the element's id (a gap is an omitted default, §2), and
/// reused when a slot already holds enough storage. The codec validates the
/// UTF-8 (§6.4); a skipped payload never reaches a collector at all.
class StringSeq extends MessageVisitor {
  StringSeq(
    this.out,
    this.cap,
    this.emax, {
    required int rcap,
    required int relemMax,
  }) : rcap = _requireCap(rcap, cap, 'StringSeq.rcap'),
       relemMax = _requireCap(relemMax, emax, 'StringSeq.relemMax');

  final List<InlineString> out;

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
  InlineString? onString(int id, int length) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    if (_overLength(this, length, emax, relemMax)) return null;
    while (out.length <= id) {
      out.add(InlineString(0));
    }
    final e = out[id];
    if (e.storage.length < length) e.storage = Uint8List(length);
    return e;
  }
}

/// Collects the elements of a `blob` wrapper array into `out`.
///
/// The bounds and the slots behave exactly as [StringSeq]'s. A blob is never
/// validated as text.
class BlobSeq extends MessageVisitor {
  BlobSeq(
    this.out,
    this.cap,
    this.emax, {
    required int rcap,
    required int relemMax,
  }) : rcap = _requireCap(rcap, cap, 'BlobSeq.rcap'),
       relemMax = _requireCap(relemMax, emax, 'BlobSeq.relemMax');

  final List<InlineBytes> out;

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
  InlineBytes? onBlob(int id, int length) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    if (_overLength(this, length, emax, relemMax)) return null;
    while (out.length <= id) {
      out.add(InlineBytes(0));
    }
    final e = out[id];
    if (e.storage.length < length) e.storage = Uint8List(length);
    return e;
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
class MessageSeq<T> extends MessageVisitor {
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
    while (out.length <= id) {
      out.add(make());
    }
    return vis(out[id]);
  }
}

/// Collects the rows of an array whose elements are themselves WRAPPER arrays.
///
/// `make` builds the collector for one row, which for a row of rows is another
/// [NestedSeq] — the recursion the depth-3 shapes need. The row's own bounds,
/// schema and receiver alike, are the row collector's; this one bounds the row
/// **index** only.
class NestedSeq<T> extends MessageVisitor {
  NestedSeq(this.out, this.cap, this.make, {required int rcap})
    : rcap = _requireCap(rcap, cap, 'NestedSeq.rcap');

  final List<List<T>> out;

  /// The schema `count:` — the row index bound (-1: none declared).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;
  final MessageVisitor Function(List<T>) make;

  /// Reserves the row at [id], **clears** it, and returns its collector.
  ///
  /// The clear is MESSAGE_SPEC §7.4 (generator#523). A row here is itself an
  /// array field, and §7.4 makes an array wrapper the exception to scope
  /// merging: the wrapper *is* the value of its field, so a later occurrence of
  /// the element id REPLACES it whole, where a re-opened struct/union element
  /// continues its scope and merges ([MessageSeq], which must therefore not do
  /// this). Growing the list only extends it UP TO the index, so without the
  /// clear a repeated element id would find the previous occurrence's elements
  /// still in place and write on top of them — measured on a generated
  /// `matstr: array<array<string>>` carrying element id 0 twice, `["a","z"]`
  /// then `["y"]`: `[["y", "z"]]` before, `[["y"]]` after.
  ///
  /// The list is cleared in place rather than replaced, because the row
  /// collector `make` returns holds that very list.
  ///
  /// Order is load-bearing: the capacity check returns FIRST, so a refused row
  /// index cannot wipe a valid earlier row — the §7.3 interaction where a
  /// destructive reset placed in front of the decision turns a loud failure
  /// into silent data loss. And [onSequenceStart] is reached only for an actual
  /// sequence header, so an element arriving as some other wire type never
  /// reaches the clear at all.
  @override
  MessageVisitor? onSequenceStart(int id) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    while (out.length <= id) {
      out.add(<T>[]);
    }
    out[id].clear();
    return make(out[id]);
  }
}

/// Collects the rows of an integer matrix — an array whose elements are compact
/// integer arrays — each row decoded straight into its slot of `out`.
///
/// `signed` selects which wire kind is this array's: a row arriving as the
/// other one contradicts the declared element type and is skipped (§7.3), not
/// rejected. `lo`/`hi` bound each element to its declared width (§7.1); equal
/// values mean "nothing narrower than the wire to check". A `bool` matrix is an
/// unsigned one with no width (any non-zero element is `true`, §4.4).
///
/// A row here is a real compact array with a real `element_count` on the wire,
/// so it carries a second pair of bounds beside the row index: `rowCount`, the
/// row's declared `count:`, and `rowCap`, the receiver's cap where the schema
/// declared none. Both are weighed at the row's header, before its storage is
/// chosen (§6.2.1).
class IntMatrixSeq extends MessageVisitor {
  IntMatrixSeq(
    this.out,
    this.cap,
    this.signed,
    int lo,
    int hi, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'IntMatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'IntMatrixSeq.rowCap'),
       range = lo == hi ? null : ElemRange(lo, hi);

  final List<InlineInt64Array> out;

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

  /// The declared element width every row carries, or `null` for none.
  final ElemRange? range;

  @override
  InlineInt64Array? onUnsignedArray(int id, int count) =>
      signed ? null : _row(id, count);

  @override
  InlineInt64Array? onSignedArray(int id, int count) =>
      signed ? _row(id, count) : null;

  InlineInt64Array? _row(int id, int count) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    if (_overLength(this, count, rowCount, rowCap)) return null;
    while (out.length <= id) {
      out.add(InlineInt64Array(0, range: range));
    }
    final r = out[id];
    if (r.storage.length < count) r.storage = Int64List(count);
    return r;
  }
}

/// Collects the rows of an fp32 matrix, each row decoded straight into its slot
/// of `out`. A row of fp64 elements contradicts the declared element type and
/// is skipped (§7.3).
///
/// `rowCount`/`rowCap` bound a row's element count exactly as [IntMatrixSeq]'s
/// do.
class Float32MatrixSeq extends MessageVisitor {
  Float32MatrixSeq(
    this.out,
    this.cap, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'Float32MatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'Float32MatrixSeq.rowCap');

  final List<InlineFloat32Array> out;

  /// The schema `count:` of the matrix — the row index bound (-1: none).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;

  /// The schema `count:` of a **row** — its element count bound (-1: none).
  final int rowCount;

  /// The **receiver cap** on a row's element count — see [IntMatrixSeq.rowCap].
  final int rowCap;

  @override
  InlineFloat32Array? onFp32Array(int id, int count) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    if (_overLength(this, count, rowCount, rowCap)) return null;
    while (out.length <= id) {
      out.add(InlineFloat32Array(0));
    }
    final r = out[id];
    if (r.capacity < count) r.storage = Float32List(count);
    return r;
  }
}

/// Collects the rows of an fp64 matrix — the twin of [Float32MatrixSeq].
class Float64MatrixSeq extends MessageVisitor {
  Float64MatrixSeq(
    this.out,
    this.cap, {
    required int rcap,
    required this.rowCount,
    required int rowCap,
  }) : rcap = _requireCap(rcap, cap, 'Float64MatrixSeq.rcap'),
       rowCap = _requireCap(rowCap, rowCount, 'Float64MatrixSeq.rowCap');

  final List<InlineFloat64Array> out;

  /// The schema `count:` of the matrix — the row index bound (-1: none).
  final int cap;

  /// The **receiver cap** on the row index — see [StringSeq.rcap].
  final int rcap;

  /// The schema `count:` of a **row** — its element count bound (-1: none).
  final int rowCount;

  /// The **receiver cap** on a row's element count — see [IntMatrixSeq.rowCap].
  final int rowCap;

  @override
  InlineFloat64Array? onFp64Array(int id, int count) {
    if (_overCapacity(this, id, cap, rcap)) return null;
    if (_overLength(this, count, rowCount, rowCap)) return null;
    while (out.length <= id) {
      out.add(InlineFloat64Array(0));
    }
    final r = out[id];
    if (r.capacity < count) r.storage = Float64List(count);
    return r;
  }
}
