import 'dart:typed_data';

import 'inline.dart';
import 'utf8.dart';
import 'wire.dart';

/// Raised by [MessageVisitor.invalidate] and caught by whichever decode engine
/// is running, which then reports `INVALID` and stops.
///
/// Private on purpose: it is a control signal, not an error a caller handles.
/// It is also the reason a visitor callback must not swallow exceptions
/// indiscriminately — a bare `catch` around a store would eat the verdict.
class _Invalidated implements Exception {
  const _Invalidated();
}

/// Raised by [MessageVisitor.limitExceeded] and caught by whichever decode
/// engine is running, which then reports `limitExceeded` and stops.
///
/// A second control signal rather than a flag on the first, because
/// CORELIB_PLAN §6.2.1 forbids folding a receiver-limit breach into `INVALID`:
/// *"exceeding one is a policy rejection — a category distinct from INVALID …
/// An implementation MUST NOT report it as `InvalidMessage`"*. The two travel
/// the same way and arrive as different outcomes.
class _LimitExceeded implements Exception {
  const _LimitExceeded();
}

/// A consumer of a SofaBuffers stream (CORELIB_PLAN §5.2, §5.3 — the *visitor*
/// pattern), and the only decode surface (§5.3.1).
///
/// **One call per field**, made at the field's header — before any payload byte
/// is consumed:
///
/// * a **scalar** arrives as its value: [onUnsigned], [onSigned], [onFp32] (or
///   [onFp32Bits] for a NaN), [onFp64]. A varint has to be read to be stepped
///   over, so delivering it costs nothing a skip would not; a scalar the
///   visitor does not want is simply ignored.
/// * an **aggregate** — [onString], [onBlob], [onUnsignedArray],
///   [onSignedArray], [onFp32Array], [onFp64Array] — is told its announced byte
///   length or element count and answers with the **destination** to decode it
///   into (an `Inline…` wrapper, §6.6.3), or `null` to skip it. The codec sets
///   the wrapper's `length` right there and writes the payload into its
///   `storage`; **nothing is called when it is whole.** Nobody reads a
///   destination while `feed` is still running — the object is complete when
///   `feed`/`decode` reports [DecodeStatus.complete] — so a completion call
///   would carry nothing (corelib-c-cpp has none either).
/// * a **sequence** is entered through [onSequenceStart], which returns the
///   visitor for its fields or `null` to skip it, and left through
///   [onSequenceEnd].
///
/// The header call is also where every bound on the field is judged, and the
/// only place (§6.2.1): a schema bound (`count`/`maxlen`, MESSAGE_SPEC §7.1) is
/// refused with [invalidate], a receiver cap on a schema-unbounded field with
/// [limitExceeded] — both before the destination is chosen, which is the
/// allocation they exist to prevent, and both dominating a truncated payload
/// (§5.2). A field answered with `null` is **skipped**: no bound applies to it
/// (§6.2.1 — "a skipped field is never capped"), its payload is stepped over
/// by its length and never inspected (§6.4 — a skipped string is never
/// UTF-8-validated), and only the wire's own structure is still checked.
///
/// Every default is "not interested": scalars are ignored, aggregates and
/// sequences skipped. A visitor overrides the calls for the fields it has a
/// place for. Booleans arrive via [onUnsigned] (any non-zero is `true`, §4.4).
abstract class MessageVisitor {
  /// Reject the running decode as `INVALID` from inside a callback.
  ///
  /// The wire layer judges what the format can decide on its own; a **schema**
  /// bound — an array index past the declared capacity, a string past its
  /// `maxlen`, a value outside its declared width — is knowable only to the
  /// consumer, and MESSAGE_SPEC §7.1 makes it INVALID all the same.
  ///
  /// Calling this stops the decode where it stands: no further field is
  /// delivered, and [Decoder.feed] / [Decoder.decode] report
  /// [DecodeStatus.invalid], which is terminal (CORELIB_PLAN §5.2).
  ///
  /// Safe from any depth, including inside a nested collector. It never
  /// returns normally.
  void invalidate() => throw const _Invalidated();

  /// Reject the running decode as [DecodeStatus.limitExceeded] from inside a
  /// callback — the receiver-cap counterpart of [invalidate].
  ///
  /// A **configured receiver limit** (CORELIB_PLAN §6.2.1) is not a statement
  /// about the bytes: they are well-formed, and the same message decodes for a
  /// receiver configured more loosely. §6.2.1 therefore forbids folding a
  /// breach into `INVALID`, and §6.3 keeps `LimitExceeded` distinct.
  ///
  /// **The decoder never raises it.** The numbers are generated code's
  /// (§6.2.1: *"the visitor decides. The codec never invents a limit of its own
  /// and never clamps to one"*), so this is the channel every receiver cap is
  /// reported through: a string's length or an array's count from the header
  /// call, and a **wrapper array's element index** — the array's length
  /// (MESSAGE_SPEC §5.1) — where the elements are collected (`lib/src/seq.dart`).
  ///
  /// Safe from any depth. It never returns normally.
  void limitExceeded() => throw const _LimitExceeded();

  void onUnsigned(int id, int value) {}
  void onSigned(int id, int value) {}
  void onFp32(int id, double value) {}

  /// Delivered for an fp32 field whose payload is a **NaN**, carrying the raw
  /// 32-bit IEEE-754 bit pattern so a signaling NaN survives bit-for-bit — a
  /// Dart `double` would quiet it (CORELIB_PLAN §4.6: never normalize). The
  /// default widens to a `double` and forwards to [onFp32], so a consumer that
  /// does not care about NaN bit patterns needs no change; override this to
  /// capture the exact bits (and re-emit them with `Encoder.writeFp32Bits`).
  void onFp32Bits(int id, int bits) {
    final b = ByteData(4)..setUint32(0, bits, Endian.little);
    onFp32(id, b.getFloat32(0, Endian.little));
  }

  void onFp64(int id, double value) {}

  /// A `string` field announcing [length] UTF-8 bytes. Return the destination
  /// to decode it into — its `capacity` at least [length] — or `null` to skip
  /// it.
  ///
  /// The codec sets the destination's `length` to [length], copies the payload
  /// into its `storage`, and validates it as UTF-8 once it is whole: invalid
  /// bytes are `INVALID` (CORELIB_PLAN §6.4). A skipped string is never
  /// inspected.
  InlineString? onString(int id, int length) => null;

  /// A `blob` field announcing [length] bytes. Return the destination —
  /// `capacity` at least [length] — or `null` to skip it.
  InlineBytes? onBlob(int id, int length) => null;

  /// An unsigned-integer array announcing [count] elements. Return the
  /// destination — `capacity` at least [count] — or `null` to skip it. Its
  /// `range`, if set, is applied to every element as it is decoded.
  ///
  /// The count is judged here, before any element: this is where §4.8 has the
  /// element kind fully known, and where an over-count refusal outranks a
  /// truncated tail (§5.2). An array of the *other* integer kind arrives on
  /// [onSignedArray] instead — for a field declared unsigned that is a type
  /// mismatch, skipped (§7.3) by returning `null` there, and no bound applies.
  InlineInt64Array? onUnsignedArray(int id, int count) => null;

  /// A signed (zig-zag) integer array announcing [count] elements — see
  /// [onUnsignedArray].
  InlineInt64Array? onSignedArray(int id, int count) => null;

  /// An fp32 array announcing [count] elements, asked once its `fixlen_word`
  /// has been read and validated — so the element kind is the real one, never
  /// a collapsed "fixlen" (§4.8). A message that ends between the count and
  /// that word is INCOMPLETE: the field cannot be identified yet.
  ///
  /// The wire payload is copied into the destination's storage byte for byte,
  /// so a signaling NaN survives (§4.6).
  InlineFloat32Array? onFp32Array(int id, int count) => null;

  /// An fp64 array announcing [count] elements — see [onFp32Array].
  InlineFloat64Array? onFp64Array(int id, int count) => null;

  /// A sequence opened. Return the visitor for its fields (which follows the
  /// same contract, recursively — `this` for a flat consumer), or `null` to
  /// skip the whole sub-sequence.
  MessageVisitor? onSequenceStart(int id) => null;

  /// The sequence whose fields this visitor received has closed.
  void onSequenceEnd() {}
}

/// The inclusive range an integer array's elements may take under the schema —
/// the `range` of an [InlineInt64Array].
///
/// Both bounds are `int`, which is what the decoder produces: a signed element
/// arrives zig-zag-decoded, an unsigned one raw, and Dart's `int` is the same
/// 64-bit two's-complement word either way.
///
/// The widest NARROWED unsigned kind is `u32`, so [max] never reaches 2^63 and
/// an unsigned wire value whose top bit is set — which Dart's `int` shows as
/// negative — is always out of range. That is why the unsigned comparison reads
/// `raw < 0 || raw > max` rather than `raw > max`: an unsigned compare, written
/// in a language without one.
class ElemRange {
  final int min;
  final int max;
  const ElemRange(this.min, this.max);
}

/// A destination whose capacity is short of the announced length or count —
/// the third refusal tier (CORELIB_PLAN §6.3): the message is well-formed and
/// within every bound it declares, so it is neither `InvalidMessage` nor
/// `LimitExceeded` but [SofabError.invalidArgument], a mistake in the call. The
/// decoder never grows what it was handed. Out of line: it never runs on the
/// hot path.
@pragma('vm:never-inline')
Never _destTooShort(int id, int have, int want) {
  throw SofabException(
    SofabError.invalidArgument,
    'destination for field $id holds $have, the field announces $want',
  );
}

// There is deliberately **no `DecoderLimits` here, and no cap state on the
// decoder at all**. CORELIB_PLAN §6.2.1 makes the three receiver-side technical
// limits mandatory on every *receiver* and says in the same breath whose they
// are: *"The numbers and the allocation are not the codec's. The limits come
// from generated code, which knows the schema and the target … What the codec
// contributes is the report and the category: it surfaces the count at the
// count/length header; for a sequence array it surfaces the index of the element
// in hand; the visitor decides. The codec never invents a limit of its own and
// never clamps to one."*
//
// So the codec below reports and never judges. The header call of every
// aggregate — [MessageVisitor.onString], [MessageVisitor.onUnsignedArray] and
// their siblings — carries the declared byte length or element count before the
// destination is chosen and before a payload byte is consumed, which is exactly
// the enforcement point §6.2.1 fixes. A consumer that has a bound to apply
// applies it there and refuses with [MessageVisitor.invalidate] (a schema
// bound: `INVALID`, MESSAGE_SPEC §7.1) or [MessageVisitor.limitExceeded] (a
// receiver cap: a policy rejection, §6.3). For a wrapper array — which has no
// count header, its length being *highest present id + 1* — the same two
// channels carry the element **index**, and the collectors in
// `lib/src/seq.dart` do the applying.
//
// A decoder-level cap could do none of this correctly. It binds every field
// indiscriminately, including the schema-bounded ones §6.2.1 forbids it to
// touch, and it fires on fields nothing was going to materialize — which §6.2.1
// forbids outright: *"A skipped field is never capped … a decode that steps over
// an over-cap field it was never going to read stays COMPLETE."*

// Internal decoder states. The two *payload* states are deliberately last and
// adjacent: they are the only ones whose bytes are opaque — no varint to
// accumulate, nothing to decide per byte — so [Decoder.feed] moves them in bulk
// and [Decoder._step] splits them off with one compare. Every other state is
// waiting for a varint, which is what lets `< _sFixPayload` stand for "a whole
// varint may be lifted straight out of the chunk".
const int _sHeader = 0;
const int _sUValue = 1; // unsigned value varint
const int _sSValue = 2; // signed value varint
const int _sFixWord = 3;
const int _sArrCount = 4; // count for int arrays (u/s)
const int _sArrElem = 5; // per-element varint for int arrays
const int _sArrFixCount = 6;
const int _sArrFixWord = 7;
const int _sFixPayload = 8; // opaque payload — bulk-copied
const int _sArrFixPayload = 9; // opaque payload — bulk-copied

/// Shortest run of payload bytes worth moving in bulk (see
/// [Decoder._bulkPayload]).
const int _bulkPayloadMin = 4;

/// Fewest chunk bytes worth entering the word-wise array-element run for (see
/// [Decoder._bulkArrElems]): one maximal varint, the reader's step size.
const int _bulkVarintMin = 10;

/// The continuation bit of all eight bytes of a 64-bit word.
const int _contBits = 0x8080808080808080;

/// Shared 8-byte staging area for reading a **single** IEEE-754 payload.
///
/// Dart offers no bits→double conversion outside typed data, and building a view
/// over the input costs ~300 instructions — far more than a scalar float read is
/// worth. Copying the 4/8 payload bytes into this one permanently-allocated
/// scratch and reading them back is several times cheaper, and it keeps a
/// float-carrying message from paying for a whole-buffer view it needs nowhere
/// else. Array payloads still use the buffer-wide view, where it amortizes.
///
/// Isolate-confined (Dart statics are per-isolate) and live only for the
/// duration of one read, so there is no sharing hazard.
final Uint8List _scratchBytes = Uint8List(8);
final ByteData _scratchData = ByteData.view(_scratchBytes.buffer);

/// Gathers eight 7-bit groups — one per byte of [x], little-endian — back into
/// the low 56 bits of a value. The inverse of the encoder's spread step, and the
/// core of the word-wise varint reader ([_ContiguousDecoder._uvarintWide]).
/// Three log-steps rather than eight shift-mask-or terms — merge adjacent 7-bit
/// groups into 14s, then 28s, then the full 56. 12 operations instead of 23.
@pragma('vm:prefer-inline')
int _unspread56(int x) {
  var v = (x & 0x007F007F007F007F) | ((x & 0x7F007F007F007F00) >>> 1);
  v = (v & 0x00003FFF00003FFF) | ((v & 0x3FFF00003FFF0000) >>> 2);
  return (v & 0xFFFFFFF) | ((v & 0x0FFFFFFF00000000) >>> 4);
}

/// Index (0..7) of the byte holding the lowest set bit of [m], where [m] only
/// ever has bits at the eight `0x80` positions — i.e. the varint's terminating
/// byte.
///
/// A three-step binary search rather than `bitLength`: `bitLength` is a real
/// method call under Dart AOT (not a count-leading-zeros intrinsic) and measured
/// ~2× the cost of the whole surrounding loop.
@pragma('vm:prefer-inline')
int _termByte(int m) {
  var idx = 0;
  var x = m;
  if ((x & 0xFFFFFFFF) == 0) {
    idx = 4;
    x >>>= 32;
  }
  if ((x & 0xFFFF) == 0) {
    idx += 2;
    x >>>= 16;
  }
  if ((x & 0xFF) == 0) idx += 1;
  return idx;
}

/// Decodes a run of array-element varints (CORELIB_PLAN §4.7) **word-wise** —
/// the shared element engine of both decode surfaces, so the one-shot path and
/// the streaming path cost the same per element and cannot drift apart.
///
/// Reads from [buf] (viewed as [bd], valid to [len]) starting at [p] and fills
/// `out[i..limit)`. Returns the position it stopped at in the low 32 bits and
/// the index it stopped at in the high bits — a packed pair rather than a record
/// so the run itself allocates nothing; both fit comfortably, `len` and `limit`
/// being bounded by `ARRAY_MAX` = 2^31−1.
///
/// It stops **before** anything it cannot settle inside the range: [limit], a
/// maximal varint that would leave the buffer, or a malformed 10-byte varint.
/// The caller's byte-wise reader then re-reads those bytes and owns the
/// INCOMPLETE/INVALID verdict — one place decides, whichever surface got here.
///
/// Callers must guarantee `out.length >= limit`.
int _varintRun(
  Uint8List buf,
  ByteData bd,
  int len,
  int p,
  Int64List out,
  int i,
  int limit,
  bool signed,
) {
  while (i < limit && p + 10 <= len) {
    int raw;
    // One 64-bit load serves every length. The short-varint cases are derived
    // from that same word rather than from extra byte loads (a bounds-checked
    // `Uint8List` read costs ~8 instructions), and the all-continuation case is
    // tested first because it is the one that cannot be short-circuited.
    final x = bd.getUint64(p, Endian.little);
    final m = ~x & _contBits;
    if (m == 0) {
      // 9- or 10-byte varint. (Folding the two tail bytes into one
      // `ByteData.getUint16` measured very slightly *worse* than two
      // `Uint8List` loads, so they stay separate.)
      final b8 = buf[p + 8];
      raw = _unspread56(x) | ((b8 & 0x7F) << 56);
      if (b8 < 0x80) {
        p += 9;
      } else {
        final last = buf[p + 9];
        if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) break; // malformed
        raw |= (last & 0x7f) << 63;
        p += 10;
      }
    } else if ((m & 0x80) != 0) {
      raw = x & 0x7F; // 1 byte — skips the ~23-op un-spread
      p += 1;
    } else if ((m & 0x8000) != 0) {
      raw = (x & 0x7F) | (((x >>> 8) & 0x7F) << 7); // 2 bytes
      p += 2;
    } else {
      final nb = _termByte(m) + 1; // 3..8 bytes
      p += nb;
      raw = _unspread56(nb == 8 ? x : x & ((1 << (nb << 3)) - 1));
    }
    out[i++] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
  }
  return (i << 32) | p;
}

/// Whether any of `out[from..to)` falls outside [range]. See [ElemRange] for why
/// the unsigned arm also rejects a negative: Dart has no unsigned compare, and a
/// wire value above 2^63 is above every bound that can exist here.
bool _elemOutOfRange(
  Int64List out,
  int from,
  int to,
  bool signed,
  ElemRange range,
) {
  for (var i = from; i < to; i++) {
    final v = out[i];
    if (signed ? (v < range.min || v > range.max) : (v < 0 || v > range.max)) {
      return true;
    }
  }
  return false;
}

/// Whether the host stores typed-data elements in wire (little-endian) order —
/// true on every platform Dart targets. Where it holds, a fixlen array's wire
/// payload *is* the byte image of the `Float32List`/`Float64List` it decodes
/// into, which is what lets the readers below copy in bulk and lets the
/// streaming decoder stage the payload in the result list itself.
final bool _hostIsLittleEndian = Endian.host == Endian.little;

/// Fills [dst] with [count] fp32 elements from little-endian wire bytes in [src]
/// starting at [srcStart], preserving each element's raw 32-bit pattern
/// (CORELIB_PLAN §4.6 — a signaling NaN must not be quieted). On a little-endian
/// host (every platform Dart targets) this is a single bulk byte copy: bit-exact
/// *and* faster than a per-element float read. A big-endian host falls back to
/// endian-swapping element reads — which cannot preserve an sNaN, but no such
/// host exists in practice.
void _readFp32Array(
  InlineFloat32Array dst,
  Uint8List src,
  int srcStart,
  int count,
) {
  if (_hostIsLittleEndian) {
    dst.byteView.setRange(0, count * 4, src, srcStart);
  } else {
    final out = dst.storage;
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 4);
    for (var i = 0; i < count; i++) {
      out[i] = bd.getFloat32(i * 4, Endian.little);
    }
  }
}

/// Byte-swaps the first [count] elements of [dst] **in place**, where the wire's
/// little-endian bytes were written straight into a big-endian host's storage.
///
/// Reading and writing the same four bytes per element, so no staging buffer is
/// needed and nothing is allocated (CORELIB_PLAN §6.6). Never runs on any
/// platform Dart currently targets; it is the reason the fast path can be a
/// plain byte copy on every one of them.
void _swapFp32InPlace(Float32List dst, int count) {
  final bd = ByteData.sublistView(dst);
  for (var i = 0; i < count; i++) {
    dst[i] = bd.getFloat32(i * 4, Endian.little);
  }
}

/// The fp64 twin of [_swapFp32InPlace].
void _swapFp64InPlace(Float64List dst, int count) {
  final bd = ByteData.sublistView(dst);
  for (var i = 0; i < count; i++) {
    dst[i] = bd.getFloat64(i * 8, Endian.little);
  }
}

/// The fp64 twin of [_readFp32Array]: [count] 8-byte little-endian elements out
/// of [src] at [srcStart] into [dst], in bulk where the host layout already
/// matches the wire.
void _readFp64Array(
  InlineFloat64Array dst,
  Uint8List src,
  int srcStart,
  int count,
) {
  if (_hostIsLittleEndian) {
    dst.byteView.setRange(0, count * 8, src, srcStart);
  } else {
    final out = dst.storage;
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 8);
    for (var i = 0; i < count; i++) {
      out[i] = bd.getFloat64(i * 8, Endian.little);
    }
  }
}

/// Streaming SofaBuffers decoder (CORELIB_PLAN §5.2).
///
/// Feed arbitrarily small chunks via [feed]; the state machine suspends and
/// resumes at **any** byte boundary. Each [feed] (and the one-shot [decode])
/// returns the three-valued [DecodeStatus] describing the bytes consumed so far —
/// there is **no** finalize step, and `incomplete` is never auto-promoted to an
/// error.
///
/// Resuming anywhere is a guarantee, not a tariff: whatever a chunk carries
/// whole is taken whole — a varint out of it in one read ([_fastVarint]), a run
/// of integer array elements 64 bits at a time ([_bulkArrElems], the same reader
/// the one-shot surface uses), an opaque payload in one copy ([_bulkPayload]) —
/// and only a field genuinely straddling a boundary falls back to the per-byte
/// state machine. The hot path touches no heap of its own: every payload lands
/// in the destination its header call returned, and a float scalar stages in a
/// reusable slot.
class Decoder {
  Decoder(MessageVisitor root) : _vis = root {
    // Every piece of bounded working state this decoder will ever use is sized
    // here, at construction, and never again (CORELIB_PLAN §6.6).
    _fscratchData = ByteData.view(_fscratch.buffer);
  }

  /// The visitor of the innermost open scope, or `null` while that scope is
  /// being skipped — held directly rather than re-read off the stack, because
  /// every field consults it several times.
  MessageVisitor? _vis;

  /// The *enclosing* scopes' visitors, innermost last; [_depth] is the number
  /// of open sequences. A plain visitor slot per level, not a wrapper object
  /// per scope — the scope carried nothing else, so a nested message allocates
  /// nothing per `sequence_start`.
  ///
  /// **Sized at construction, to its full extent** (CORELIB_PLAN §6.6): this is
  /// the parse stack the section names as permitted bounded working state, and
  /// the permission is conditional on the size coming from this document's
  /// [maxDepth] rather than from the wire. A list that grew as nesting deepened
  /// would allocate on a `feed` path, which is exactly what §6.6 forbids —
  /// "growing it afterwards is forbidden even where the ceiling it grows
  /// towards is correct".
  final List<MessageVisitor?> _enclosing = List<MessageVisitor?>.filled(
    maxDepth,
    null,
  );

  /// Number of open sequences — the number of valid entries in [_enclosing].
  int _depth = 0;

  int _state = _sHeader;
  bool _terminal = false; // an INVALID / limitExceeded outcome is sticky
  DecodeStatus _terminalStatus = DecodeStatus.invalid;

  // Skip-subtree depth: >0 means we are inside a skipped sequence (CORELIB_PLAN
  // §5.2 auto-skip). Independent of the frame stack, which still tracks open
  // sequences for boundary/COMPLETE detection.
  int _skipDepth = 0;

  // Varint accumulator (shared; only one varint is ever in progress).
  int _v = 0;
  int _vn = 0;

  // Current field context.
  int _fieldId = 0;
  bool _read = false; // materialize this field's value?

  // Fixlen payload context.
  int _fixSubtype = 0;
  int _payloadTotal = 0;
  int _payloadPos = 0;

  /// Where the payload in flight is being written — **the caller's
  /// destination** (the `storage` of the [InlineBytes] a string/blob header
  /// call returned, or the byte view of an fp32/fp64 array's), or the
  /// decoder's own 8-byte landing zone for an `fp32`/`fp64` scalar, or `null`
  /// while a payload is being walked rather than read.
  ///
  /// There is no library-owned carry buffer: a payload split across chunks is
  /// joined here, in the caller's own storage, one piece per `feed`
  /// (CORELIB_PLAN §6.6.2).
  Uint8List? _payloadBuf;

  // Int-array context.
  int _arrType = 0; // WireType.arrayUnsigned or arraySigned
  int _arrCount = 0;
  int _arrIndex = 0;
  Int64List? _arrInts;
  // The declared element width for the array in flight — the destination's
  // `range`, read once at the count word and applied per element below, so the
  // per-element cost is two integer compares and no call.
  ElemRange? _arrElemRange;

  // Fixlen-array context: the element subtype and, for a big-endian host only,
  // the destination storage to swap in place once the payload is whole.
  int _arrFixSubtype = 0;
  TypedData? _arrDest;

  /// Reusable 8-byte staging area for one `fp32`/`fp64` scalar payload, and its
  /// `ByteData` twin — the widest a float payload gets. A float field therefore
  /// allocates nothing: no per-field payload buffer and no per-field typed-data
  /// view (whose construction costs ~300 instructions under Dart AOT, several
  /// times a float read). Per **decoder**, not a shared static, so interleaved
  /// decoders cannot overwrite each other's half-arrived payload.
  ///
  /// Allocated **at construction**, not on first float: §6.6 permits bounded
  /// working state only where it is "sized to its full extent when the codec is
  /// constructed", and a `late final` initialiser runs on a `feed` path.
  final Uint8List _fscratch = Uint8List(8);
  late final ByteData _fscratchData;

  /// Feeds a chunk of raw bytes. Returns the outcome for everything consumed so
  /// far (CORELIB_PLAN §5.2).
  DecodeStatus feed(List<int> data) {
    if (_terminal) return _terminalStatus;
    try {
      return _feed(data);
    } on _Invalidated {
      _terminal = true;
      return _terminalStatus = DecodeStatus.invalid;
    } on _LimitExceeded {
      _terminal = true;
      return _terminalStatus = DecodeStatus.limitExceeded;
    }
  }

  /// The byte loop itself. Split out so it keeps a frame of its own: the
  /// `try` above must not sit around the loop the decoder's throughput is
  /// measured on.
  DecodeStatus _feed(List<int> data) {
    // Everything below reads bytes through a `Uint8List`: on that type AOT
    // compiles an element read down to a load, where `List<int>` indexing is an
    // interface call per byte, and only there can the bulk moves below reach
    // memcpy and a 64-bit varint load. A caller that hands over some other
    // `List<int>` gets the byte-wise reader instead — copying the chunk to get
    // the fast path would be a chunk copy the wire sizes, which §6.6 forbids
    // the codec outright.
    if (data is! Uint8List) return _feedSlow(data);
    final chunk = data;
    final n = chunk.length;
    // Built at most once per `feed`, and only for a chunk that actually carries
    // array elements: `ByteData.sublistView` is a §6.6.2 language-forced handle
    // — it addresses the caller's chunk, carries no message bytes of its own,
    // and costs the same whatever the chunk's length — but it is not free, so
    // it is hoisted out of the per-run call it used to sit in.
    ByteData? chunkData;
    var i = 0;
    while (i < n) {
      final state = _state;
      if (state >= _sFixPayload) {
        // Opaque payload: move the run this chunk holds in one go.
        if (n - i >= _bulkPayloadMin) {
          i += _bulkPayload(chunk, i, n);
          if (_payloadPos == _payloadTotal && !_payloadComplete()) {
            _terminal = true;
            return _terminalStatus;
          }
          if (i == n) break;
          continue;
        }
      } else if (_vn == 0) {
        // A varint state with nothing accumulated yet — so the chunk may hold
        // whole varints, and reading them as varints beats one state-machine
        // dispatch per byte by roughly an order of magnitude.
        if (state == _sArrElem) {
          chunkData ??= ByteData.sublistView(chunk);
          final took = _bulkArrElems(chunk, chunkData, i, n);
          if (took < 0) {
            _terminal = true;
            return _terminalStatus;
          }
          i += took;
          if (i == n) break;
        }
        final took = _fastVarint(chunk, i, n);
        if (took != 0) {
          i += took;
          final v = _v;
          _v = 0;
          if (!_onVarint(v)) {
            _terminal = true;
            return _terminalStatus;
          }
          continue;
        }
      }
      if (!_step(chunk[i])) {
        _terminal = true;
        return _terminalStatus;
      }
      i++;
    }
    return _boundaryStatus();
  }

  /// The byte-wise reader for a chunk that is not a `Uint8List`.
  ///
  /// One `_step` per byte, masked to 8 bits exactly as `Uint8List.fromList`
  /// would truncate — the same state machine, only without the bulk moves,
  /// which need the concrete type. It exists because the alternative is
  /// copying the chunk, and a copy the *wire* sizes is payload storage the
  /// codec may not take (CORELIB_PLAN §6.6). Callers wanting the fast path
  /// hand over a `Uint8List`.
  DecodeStatus _feedSlow(List<int> data) {
    final n = data.length;
    for (var i = 0; i < n; i++) {
      if (!_step(data[i] & 0xFF)) {
        _terminal = true;
        return _terminalStatus;
      }
    }
    return _boundaryStatus();
  }

  /// Reads one **whole** varint out of `data[from..end)` into [_v], and returns
  /// how many bytes it took — or 0, leaving [_v] untouched, when the chunk does
  /// not carry the whole of it or the encoding is malformed.
  ///
  /// Both refusals hand the bytes back to the byte-wise reader unread, which is
  /// where suspend-and-resume and the INVALID verdict live: this is a fast path,
  /// never a second opinion. Caller must have `_vn == 0` (nothing accumulated).
  int _fastVarint(Uint8List data, int from, int end) {
    var p = from;
    var v = 0;
    var shift = 0;
    while (p < end) {
      final b = data[p++];
      v |= (b & 0x7F) << shift;
      if (b < 0x80) {
        _v = v;
        return p - from;
      }
      shift += 7;
      if (shift == 63) {
        // The 10th byte may set only bit 63 and must terminate the varint.
        if (p >= end) return 0;
        final last = data[p++];
        if ((last & 0x80) != 0 || (last & 0x7F) > 0x01) return 0; // malformed
        _v = v | ((last & 0x7F) << 63);
        return p - from;
      }
    }
    return 0;
  }

  /// Takes the run of opaque payload bytes this chunk holds — a `string`,
  /// `blob`, `fp32`/`fp64` value or a fixlen array's elements — in **one move**
  /// instead of one state-machine dispatch per byte, and returns how many it
  /// took. Completion is the caller's to notice ([_payloadComplete]), the same
  /// as for the byte-wise [_stepPayload], so the value is settled from one
  /// place however the payload arrived.
  int _bulkPayload(Uint8List data, int from, int end) {
    final want = _payloadTotal - _payloadPos;
    final have = end - from;
    final take = want < have ? want : have;
    if (take <= 0) return 0;
    if (_read) {
      _payloadBuf!.setRange(_payloadPos, _payloadPos + take, data, from);
    }
    _payloadPos += take;
    return take;
  }

  /// Takes the run of **whole array-element varints** this chunk can supply in
  /// one word-wise pass ([_varintRun]) instead of one state-machine dispatch per
  /// byte, and returns how many bytes it took (0 when there is nothing to take;
  /// −1 when an element turned out to be outside its declared width, which is
  /// terminal INVALID).
  ///
  /// Like [_bulkPayload] it stops one **element** short of the array's end: the
  /// last one goes through [_onArrElem], which owns the return to the field
  /// boundary, so the array is closed in exactly one place whether it arrived
  /// byte-by-byte or in a single chunk. It also declines a skipped array, whose
  /// elements are walked rather than materialized.
  int _bulkArrElems(Uint8List data, ByteData bd, int from, int end) {
    final out = _arrInts;
    final limit = _arrCount - 1;
    final first = _arrIndex;
    // The run reads a maximal varint at a time, so it needs that much room.
    // (`feed` only calls this with nothing accumulated, `_vn == 0`.)
    if (out == null || first >= limit || end - from < _bulkVarintMin) return 0;
    final signed = _arrType == WireType.arraySigned;
    final packed = _varintRun(data, bd, end, from, out, first, limit, signed);
    _arrIndex = packed >>> 32;
    // The declared width, applied AT the element (§7.1) — over the run rather
    // than one element at a time, which is the same `feed` call and so the same
    // reported outcome, INVALID still outranking a truncated tail (§5.2).
    final range = _arrElemRange;
    if (range != null &&
        _elemOutOfRange(out, first, _arrIndex, signed, range)) {
      _fail(DecodeStatus.invalid);
      return -1;
    }
    return (packed & 0xFFFFFFFF) - from;
  }

  DecodeStatus _boundaryStatus() {
    // COMPLETE only at a field boundary with no open sequence (CORELIB_PLAN
    // §5.2 framing invariant).
    if (_state == _sHeader && _vn == 0 && _depth == 0) {
      return DecodeStatus.complete;
    }
    return DecodeStatus.incomplete;
  }

  // Accumulate one byte into the varint. Returns 1=complete, 0=need more,
  // -1=overlong (>64 bits, INVALID).
  int _vfeed(int b) {
    if (_vn == 9) {
      // 10th byte: only bit 63 may be set, and it must terminate.
      if ((b & 0x80) != 0 || (b & 0x7F) > 0x01) return -1;
    } else if (_vn > 9) {
      return -1;
    }
    _v |= (b & 0x7F) << (7 * _vn);
    _vn++;
    return (b & 0x80) == 0 ? 1 : 0;
  }

  void _vreset() {
    _v = 0;
    _vn = 0;
  }

  bool _fail(DecodeStatus status) {
    _terminalStatus = status;
    return false; // propagate as terminal
  }

  // Process a single byte. Returns false on a terminal outcome.
  //
  // Every state but the two opaque payloads is waiting for a varint, so the
  // accumulate-and-test preamble lives here once rather than in each of them;
  // the state's actual decision is [_onVarint], which [feed]'s whole-varint fast
  // path reaches directly.
  bool _step(int b) {
    if (_state >= _sFixPayload) return _stepPayload(b);
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final v = _v;
    _vreset();
    return _onVarint(v);
  }

  /// Acts on the varint [v] the current state was waiting for, however it was
  /// read — accumulated byte by byte by [_step] or lifted whole out of the chunk
  /// by [_fastVarint]. One place decides per state, so the two readers cannot
  /// drift apart.
  bool _onVarint(int v) {
    switch (_state) {
      case _sHeader:
        return _onHeader(v);
      case _sUValue:
        _state = _sHeader;
        if (_read) _vis!.onUnsigned(_fieldId, v);
        return true;
      case _sSValue:
        _state = _sHeader;
        if (_read) _vis!.onSigned(_fieldId, (v >>> 1) ^ -(v & 1));
        return true;
      case _sFixWord:
        return _onFixWord(v);
      case _sArrCount:
        return _onArrCount(v);
      case _sArrElem:
        return _onArrElem(v);
      case _sArrFixCount:
        return _onArrFixCount(v);
      case _sArrFixWord:
        return _onArrFixWord(v);
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _onHeader(int header) {
    final type = header & 0x7;
    final id = header >>> 3;
    if (id > idMax) return _fail(DecodeStatus.invalid); // id > ID_MAX (§6.2)
    _fieldId = id;
    // Inside a skipped sequence [_vis] is null: every field there is walked.
    // Otherwise a field is read, and its own header call decides the rest — a
    // scalar is delivered, an aggregate asks for its destination.
    _read = _vis != null;

    switch (type) {
      case WireType.unsigned:
        _state = _sUValue;
        return true;
      case WireType.signed:
        _state = _sSValue;
        return true;
      case WireType.fixlen:
        _state = _sFixWord;
        return true;
      case WireType.arrayUnsigned:
      case WireType.arraySigned:
        _arrType = type;
        _state = _sArrCount;
        return true;
      case WireType.arrayFixlen:
        _state = _sArrFixCount;
        return true;
      case WireType.sequenceStart:
        return _openSequence(id);
      case WireType.sequenceEnd:
        return _closeSequence();
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _openSequence(int id) {
    // Open count includes skipped sequences, so COMPLETE waits for them too.
    if (_depth >= maxDepth) {
      return _fail(DecodeStatus.invalid); // nesting past MAX_DEPTH
    }
    _enclosing[_depth++] = _vis;
    if (_skipDepth > 0) {
      _skipDepth++;
      _vis = null;
      return true;
    }
    final child = _vis!.onSequenceStart(id);
    if (child == null) _skipDepth = 1;
    _vis = child;
    return true;
  }

  bool _closeSequence() {
    if (_depth == 0) {
      return _fail(DecodeStatus.invalid); // sequence-end with no open sequence
    }
    final closed = _vis;
    final top = --_depth;
    _vis = _enclosing[top];
    _enclosing[top] = null; // do not keep a closed scope's visitor alive
    if (_skipDepth > 0) {
      _skipDepth--;
    } else {
      closed?.onSequenceEnd();
    }
    return true;
  }

  bool _onFixWord(int word) {
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (length > fixlenMax) return _fail(DecodeStatus.invalid);
    if (subtype >= 0x4) return _fail(DecodeStatus.invalid); // reserved
    if (subtype == FixlenType.fp32 && length != 4) {
      return _fail(DecodeStatus.invalid);
    }
    if (subtype == FixlenType.fp64 && length != 8) {
      return _fail(DecodeStatus.invalid);
    }
    _fixSubtype = subtype;
    _payloadTotal = length;
    _payloadPos = 0;
    _payloadBuf = null;
    if (_read) {
      if (subtype >= FixlenType.string) {
        // The header call, before the payload and so before truncation can be
        // surfaced: a length refused inside it (a schema `maxlen` through
        // [MessageVisitor.invalidate], a receiver cap through
        // [MessageVisitor.limitExceeded]) dominates a short payload (§5.2) and
        // lands before any storage is chosen (§6.2.1). What it returns is where
        // the payload goes — the caller's storage, one piece per `feed`
        // (§6.6.3); `null` turns the field into a walk.
        final InlineBytes? dest = subtype == FixlenType.string
            ? _vis!.onString(_fieldId, length)
            : _vis!.onBlob(_fieldId, length);
        if (dest == null) {
          _read = false;
        } else {
          final storage = dest.storage;
          if (storage.length < length) {
            _destTooShort(_fieldId, storage.length, length);
          }
          dest.length = length;
          _payloadBuf = storage;
        }
      } else {
        // A float payload stages in the reusable per-decoder landing zone (4/8
        // bytes, both validated above) and is delivered as a value.
        _payloadBuf = _fscratch;
      }
    }
    _state = _sFixPayload;
    return length == 0 ? _payloadComplete() : true;
  }

  /// One opaque payload byte — a `string`/`blob`/float value or a fixlen array
  /// element — into the staging area, and the payload's completion when it is
  /// the last one.
  bool _stepPayload(int b) {
    if (_read) _payloadBuf![_payloadPos] = b;
    _payloadPos++;
    if (_payloadPos < _payloadTotal) return true;
    return _payloadComplete();
  }

  /// Settles a payload that has just become whole, however its bytes arrived —
  /// one byte at a time through [_stepPayload] or in a single move through
  /// [_bulkPayload] — and reopens the field boundary.
  bool _payloadComplete() {
    if (_state == _sFixPayload) {
      if (!_finishFixlen()) return false;
    } else if (_read && !_hostIsLittleEndian) {
      _swapFixArray();
    }
    _state = _sHeader;
    return true;
  }

  bool _finishFixlen() {
    if (!_read) return true;
    switch (_fixSubtype) {
      case FixlenType.fp32:
        {
          final view = _fscratchData;
          final v = view.getFloat32(0, Endian.little);
          // Non-NaN widens to a double and back losslessly (hot path). A NaN can
          // carry a payload/signaling bit the double would quiet, so re-read the
          // raw wire bits and deliver those (§4.6: never normalize).
          if (v.isNaN) {
            _vis!.onFp32Bits(_fieldId, view.getUint32(0, Endian.little));
          } else {
            _vis!.onFp32(_fieldId, v);
          }
          return true;
        }
      case FixlenType.fp64:
        _vis!.onFp64(_fieldId, _fscratchData.getFloat64(0, Endian.little));
        return true;
      case FixlenType.string:
        // The payload is whole in the caller's destination: validate it there,
        // strictly (§6.4 — no U+FFFD substitution). Only a string being read
        // reaches this point; a skipped one is never inspected.
        if (!utf8Valid(_payloadBuf!, 0, _payloadTotal)) {
          return _fail(DecodeStatus.invalid);
        }
        return true;
      case FixlenType.blob:
        return true;
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _onArrCount(int count) {
    // ARRAY_MAX is an *unsigned* ceiling on a full u64 count word (§6.2, §4.8),
    // and Dart has no unsigned compare: a count with bit 63 set is a negative
    // int here, so `> arrayMax` alone would let it through. Rejected before any
    // `count * length` and any cursor move (§7.2 item 5).
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    _arrElemRange = null;
    _arrInts = null;
    if (_read) {
      // The header call, before any element (and so before truncation): an
      // integer array carries no second word, so the element kind is already
      // fully known here (§4.8). A count refused inside it dominates a short
      // element tail (§5.2); what it returns is where the elements go.
      final dest = _arrType == WireType.arraySigned
          ? _vis!.onSignedArray(_fieldId, count)
          : _vis!.onUnsignedArray(_fieldId, count);
      if (dest == null) {
        _read = false;
      } else {
        final storage = dest.storage;
        if (storage.length < count) {
          _destTooShort(_fieldId, storage.length, count);
        }
        dest.length = count;
        _arrInts = storage;
        _arrElemRange = dest.range;
      }
    }
    _arrCount = count;
    _arrIndex = 0;
    _state = count == 0 ? _sHeader : _sArrElem;
    return true;
  }

  bool _onArrElem(int raw) {
    if (_read) {
      final signed = _arrType == WireType.arraySigned;
      final v = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
      // The declared width, applied AT the element (§7.1): an array that never
      // completes is INVALID all the same, and §5.2 makes this element's
      // INVALID outrank that truncation.
      final r = _arrElemRange;
      if (r != null &&
          (signed ? (v < r.min || v > r.max) : (v < 0 || v > r.max))) {
        return _fail(DecodeStatus.invalid);
      }
      _arrInts![_arrIndex] = v;
    }
    _arrIndex++;
    if (_arrIndex < _arrCount) return true;
    _state = _sHeader;
    return true;
  }

  bool _onArrFixCount(int count) {
    // Unsigned ceiling — see [_onArrCount]. This one also guards the
    // `_arrCount * length` below, which a bit-63 count would wrap.
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    // NO header call here: for a fixlen array the element subtype lives in the
    // *next* word, and §4.8 requires it to be decided before the field is
    // offered — a mismatched subtype is another field's shape (§7.3), and
    // whether this count is even this field's depends on it. The call is made
    // in [_onArrFixWord]; only the format ceiling above belongs to the bare
    // count word.
    _arrCount = count;
    _arrIndex = 0;
    _state = _sArrFixWord;
    return true;
  }

  bool _onArrFixWord(int word) {
    final length = word >>> 3;
    final subtype = word & 0x7;
    // Only fp32/fp64 are legal in a fixlen array (CORELIB_PLAN §4.8).
    if (subtype == FixlenType.fp32) {
      if (length != 4) return _fail(DecodeStatus.invalid);
    } else if (subtype == FixlenType.fp64) {
      if (length != 8) return _fail(DecodeStatus.invalid);
    } else {
      return _fail(DecodeStatus.invalid); // string/blob/reserved not allowed
    }
    _arrFixSubtype = subtype;
    _payloadTotal = _arrCount * length;
    _payloadPos = 0;
    _arrDest = null;
    _payloadBuf = null;
    if (_read) {
      // The subtype is known and legal: the §4.8 point at which the field can be
      // offered, carrying the real element kind — still before the payload, so
      // an over-count refused here dominates a short tail (§5.2).
      //
      // NO staging buffer, and nothing to do at the end: the arriving wire bytes
      // are written straight into the destination's storage, because a fixlen
      // array's payload already is that list's little-endian byte image, and
      // the byte view they go through is the one the destination keeps. A
      // (hypothetical) big-endian host writes the same bytes and swaps them in
      // place once the payload is whole, which still allocates nothing.
      if (subtype == FixlenType.fp32) {
        final dest = _vis!.onFp32Array(_fieldId, _arrCount);
        if (dest == null) {
          _read = false;
        } else {
          final have = dest.capacity;
          if (have < _arrCount) _destTooShort(_fieldId, have, _arrCount);
          dest.length = _arrCount;
          _arrDest = dest.storage;
          _payloadBuf = dest.byteView;
        }
      } else {
        final dest = _vis!.onFp64Array(_fieldId, _arrCount);
        if (dest == null) {
          _read = false;
        } else {
          final have = dest.capacity;
          if (have < _arrCount) _destTooShort(_fieldId, have, _arrCount);
          dest.length = _arrCount;
          _arrDest = dest.storage;
          _payloadBuf = dest.byteView;
        }
      }
    }
    _state = _sArrFixPayload;
    return _payloadTotal == 0 ? _payloadComplete() : true;
  }

  /// A big-endian host only: the elements landed in the caller's list in wire
  /// order and are swapped in place. Never runs on a platform Dart targets.
  void _swapFixArray() {
    final out = _arrDest!;
    if (_arrFixSubtype == FixlenType.fp32) {
      _swapFp32InPlace(out as Float32List, _arrCount);
    } else {
      _swapFp64InPlace(out as Float64List, _arrCount);
    }
  }

  /// One-shot decode of a whole, already-in-memory [bytes] buffer into
  /// [visitor] (CORELIB_PLAN §6.1 convenience). This is the common case
  /// (`deserialize`, any message that fits in memory), so it runs the fast
  /// **contiguous** path — advancing an index over the buffer rather than the
  /// per-byte streaming state machine — for a large decode speed-up. It
  /// produces byte-identical visitor calls and the same [DecodeStatus] as
  /// feeding the same bytes through [feed]; use a streaming [Decoder] + [feed]
  /// when the input arrives in chunks.
  ///
  /// A `List<int>` that is not a `Uint8List` takes the streaming engine
  /// instead: the contiguous walker needs the concrete type for its bulk moves,
  /// and copying the input to get it would be a copy the *wire* sizes, which
  /// §6.6 forbids the codec. Same visitor calls, same outcome — one engine is
  /// simply faster on the type it can index directly.
  static DecodeStatus decode(List<int> bytes, MessageVisitor visitor) {
    if (bytes is Uint8List) {
      return _ContiguousDecoder(bytes).run(visitor);
    }
    return Decoder(visitor).feed(bytes);
  }
}

/// Fast one-shot decoder for a fully-contiguous buffer. Advances an index over
/// the bytes (the protobuf-style "advance a pointer over a contiguous buffer"),
/// with no per-byte state machine and no `Decoder`/frame allocation. Recursive
/// descent over sequences. Semantics — decode outcomes, INVALID-over-INCOMPLETE
/// precedence, and the header hooks a consumer applies its bounds in — match
/// [Decoder.feed] exactly (both are covered by the same conformance vectors).
class _ContiguousDecoder {
  _ContiguousDecoder(this._buf) : _len = _buf.length;

  final Uint8List _buf;
  final int _len;
  int _pos = 0;

  ByteData? _bdCache;

  /// Wide view of [_buf], created **on first use**.
  ///
  /// Constructing a typed-data view costs ~300 instructions under Dart AOT —
  /// more than decoding a whole small message — so it is confined to the places
  /// that amortize it over many elements (array payloads, §4.7–4.8) and created
  /// only if such a field actually turns up. Scalar reads never trigger it: the
  /// varint reader is a byte loop and one-off floats go through [_scratchData].
  @pragma('vm:prefer-inline')
  ByteData get _bd =>
      _bdCache ??= ByteData.view(_buf.buffer, _buf.offsetInBytes, _len);
  // `complete` doubles as the "still ok" sentinel while walking.
  DecodeStatus _st = DecodeStatus.complete;

  DecodeStatus run(MessageVisitor root) {
    try {
      _walk(root, 0);
    } on _Invalidated {
      return DecodeStatus.invalid;
    } on _LimitExceeded {
      return DecodeStatus.limitExceeded;
    }
    return _st;
  }

  // Reads an unsigned LEB128 varint. On end-of-buffer sets INCOMPLETE; on an
  // overlong (>64-bit) varint sets INVALID. Value valid only when `_st` stays
  // `complete`.
  //
  // Three tiers, cheapest first: a single-byte varint (the overwhelmingly common
  // case — field headers, small ids, counts, small values), then the word-wise
  // reader when a maximal varint is guaranteed in bounds, then the byte loop for
  // the last few bytes of the buffer.
  @pragma('vm:prefer-inline')
  int _uvarint() {
    final p = _pos;
    if (p < _len) {
      final b = _buf[p];
      if (b < 0x80) {
        _pos = p + 1;
        return b;
      }
      // Hand the byte on rather than making the continuation re-read it.
      return _uvarintMulti(b);
    }
    _st = DecodeStatus.incomplete;
    return 0;
  }

  /// Continuation of a varint whose first byte [b0] is already in hand (and had
  /// its continuation bit set), byte at a time.
  ///
  /// Deliberately *not* the word-wise reader: that needs the [_bd] view, whose
  /// ~300-instruction construction only pays off when amortized over many
  /// elements. A scalar field carries one varint, so the byte loop wins — the
  /// word-wise reader lives in the array element loop ([_intArray]) instead.
  /// This is also the path that reports INCOMPLETE.
  int _uvarintMulti(int b0) {
    final buf = _buf;
    final len = _len;
    var p = _pos + 1; // [b0] is the byte at _pos
    var v = b0 & 0x7F;
    var shift = 7;
    while (p < len) {
      final b = buf[p++];
      v |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        _pos = p;
        return v;
      }
      shift += 7;
      if (shift == 63) {
        // The 10th byte may set only bit 63 and must terminate the varint.
        if (p >= len) break;
        final last = buf[p++];
        _pos = p;
        if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) {
          _st = DecodeStatus.invalid;
          return 0;
        }
        return v | ((last & 0x7f) << 63);
      }
    }
    _pos = p;
    _st = DecodeStatus.incomplete;
    return 0;
  }

  void _walk(MessageVisitor? vis, int depth) {
    while (_pos < _len) {
      final header = _uvarint();
      if (_st != DecodeStatus.complete) return;
      final type = header & 0x7;
      final id = header >>> 3;
      if (id > idMax) {
        _st = DecodeStatus.invalid; // id > ID_MAX (§6.2)
        return;
      }
      // `vis == null` inside a skipped sequence: every field there is walked.
      switch (type) {
        case WireType.unsigned:
          final val = _uvarint();
          if (_st != DecodeStatus.complete) return;
          vis?.onUnsigned(id, val);
          break;
        case WireType.signed:
          final raw = _uvarint();
          if (_st != DecodeStatus.complete) return;
          vis?.onSigned(id, (raw >>> 1) ^ -(raw & 1));
          break;
        case WireType.fixlen:
          if (!_fixlen(vis, id)) return;
          break;
        case WireType.arrayUnsigned:
        case WireType.arraySigned:
          if (!_intArray(vis, id, type == WireType.arraySigned)) return;
          break;
        case WireType.arrayFixlen:
          if (!_fixArray(vis, id)) return;
          break;
        case WireType.sequenceStart:
          if (depth >= maxDepth) {
            _st = DecodeStatus.invalid;
            return;
          }
          final child = vis?.onSequenceStart(id);
          _walk(child, depth + 1);
          if (_st != DecodeStatus.complete) return;
          break;
        case WireType.sequenceEnd:
          if (depth == 0) {
            _st = DecodeStatus.invalid; // unbalanced end, no open sequence
            return;
          }
          vis?.onSequenceEnd();
          return; // hand control back to the parent scope
      }
    }
    if (depth != 0) _st = DecodeStatus.incomplete; // sequence never closed
  }

  bool _fixlen(MessageVisitor? vis, int id) {
    final word = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (length > fixlenMax) return _bad(DecodeStatus.invalid);
    if (subtype >= 0x4) return _bad(DecodeStatus.invalid);
    if (subtype == FixlenType.fp32 && length != 4) {
      return _bad(DecodeStatus.invalid);
    }
    if (subtype == FixlenType.fp64 && length != 8) {
      return _bad(DecodeStatus.invalid);
    }
    // The header call comes first — before the truncation check, so a length
    // refused inside it dominates a short payload (§5.2) — and at the same point
    // the streaming surface makes it, so both surfaces make the same calls in
    // the same order on the same bytes (§6.7.1).
    InlineBytes? dest;
    if (vis != null && subtype >= FixlenType.string) {
      dest = subtype == FixlenType.string
          ? vis.onString(id, length)
          : vis.onBlob(id, length);
      if (dest != null) {
        final have = dest.storage.length;
        if (have < length) _destTooShort(id, have, length);
        dest.length = length;
      }
    }
    if (_pos + length > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += length;
    if (vis == null) return true;
    switch (subtype) {
      case FixlenType.fp32:
        {
          // Stage the 4 payload bytes rather than building a view (see
          // [_scratchData]).
          final buf = _buf;
          final s = _scratchBytes;
          s[0] = buf[start];
          s[1] = buf[start + 1];
          s[2] = buf[start + 2];
          s[3] = buf[start + 3];
          final v = _scratchData.getFloat32(0, Endian.little);
          // A NaN goes out as raw bits so a signaling NaN's is-quiet bit is not
          // set by widening to a double (§4.6).
          if (v.isNaN) {
            vis.onFp32Bits(id, _scratchData.getUint32(0, Endian.little));
          } else {
            vis.onFp32(id, v);
          }
          break;
        }
      case FixlenType.fp64:
        // `setRange` between two `Uint8List`s hits a bulk copy and measured
        // cheaper than eight indexed stores at this width.
        _scratchBytes.setRange(0, 8, _buf, start);
        vis.onFp64(id, _scratchData.getFloat64(0, Endian.little));
        break;
      case FixlenType.string:
      case FixlenType.blob:
        if (dest == null) return true; // skipped: never inspected (§6.4)
        // The payload is **copied** into the caller's destination, exactly as
        // the streaming surface copies it: §6.7.1 gives the one-shot path no
        // view exemption — "decode(buffer) copies too".
        final d = dest.storage;
        if (length != 0) d.setRange(0, length, _buf, start);
        if (subtype == FixlenType.string && !utf8Valid(d, 0, length)) {
          return _bad(DecodeStatus.invalid);
        }
        break;
    }
    return true;
  }

  bool _intArray(MessageVisitor? vis, int id, bool signed) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling: the count word is a full u64, so a count with bit 63
    // set lands as a negative Dart int and `> arrayMax` alone misses it (§6.2,
    // §4.8).
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    // The header call, before the element loop and so before truncation — an
    // over-count refused inside it dominates a short tail (§5.2). An integer
    // array carries no second word, so the element kind is fully known here
    // (§4.8).
    final dest = vis == null
        ? null
        : signed
        ? vis.onSignedArray(id, count)
        : vis.onUnsignedArray(id, count);
    if (dest == null) {
      // Skipped: walk the element varints without materializing anything.
      for (var i = 0; i < count; i++) {
        _uvarint();
        if (_st != DecodeStatus.complete) return false;
      }
      return true;
    }
    final out = dest.storage;
    if (out.length < count) _destTooShort(id, out.length, count);
    dest.length = count;
    final range = dest.range;
    var i = 0;
    // Word-wise element run — the same [_varintRun] the streaming surface uses,
    // so both cost the same per element. Entered only when a maximal varint is
    // in bounds, which is also the condition under which building the [_bd] view
    // pays for itself: a short array near the end of the buffer skips it
    // entirely and takes the byte-wise reader below.
    if (_pos + 10 <= _len) {
      final packed = _varintRun(_buf, _bd, _len, _pos, out, 0, count, signed);
      i = packed >>> 32;
      _pos = packed & 0xFFFFFFFF;
    }
    // Tail: the last elements, where a 64-bit load would overrun the buffer —
    // and the malformed 10-byte varint the run declines to settle. Also the path
    // that reports INCOMPLETE on a short element run.
    for (; i < count; i++) {
      final raw = _uvarint();
      if (_st != DecodeStatus.complete) {
        // The array does not complete, but the elements already decoded are on
        // the wire all the same, and §5.2 makes one outside its declared width
        // outrank this truncation (generator#267). Checked HERE rather than in
        // the loops above so the word-wise hot path stays a pure decode: the
        // prefix is walked only when the array fails.
        if (range != null && _elemOutOfRange(out, 0, i, signed, range)) {
          return _bad(DecodeStatus.invalid);
        }
        return false;
      }
      out[i] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
    }
    // ... and the same sweep once the array HAS arrived: an element outside its
    // declared width is INVALID wherever it sits (§7.1), exactly as
    // [Decoder.feed] finds it element by element (#38). One pass over an
    // in-cache `Int64List`, and only for a field that declares a narrowed width.
    if (range != null && _elemOutOfRange(out, 0, count, signed, range)) {
      return _bad(DecodeStatus.invalid);
    }
    return true;
  }

  bool _fixArray(MessageVisitor? vis, int id) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling — see [_intArray]. It also keeps `count * length` below
    // from wrapping, which would move `_pos` backwards.
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    // NO header call yet: §4.8 has the element subtype decided first, so the
    // call waits for the word below. EOF between the two words is therefore
    // INCOMPLETE, not INVALID.
    final word = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (subtype == FixlenType.fp32) {
      if (length != 4) return _bad(DecodeStatus.invalid);
    } else if (subtype == FixlenType.fp64) {
      if (length != 8) return _bad(DecodeStatus.invalid);
    } else {
      return _bad(DecodeStatus.invalid);
    }
    // Subtype known and legal: the header call now, carrying the real element
    // kind, still before the payload (thus before truncation) — an over-count
    // refused here dominates a short tail (§5.2). Made for count == 0 too.
    final total = count * length;
    if (subtype == FixlenType.fp32) {
      final dest = vis?.onFp32Array(id, count);
      if (dest != null) {
        if (dest.capacity < count) _destTooShort(id, dest.capacity, count);
        dest.length = count;
        if (_pos + total > _len) return _bad(DecodeStatus.incomplete);
        _readFp32Array(dest, _buf, _pos, count);
        _pos += total;
        return true;
      }
    } else {
      final dest = vis?.onFp64Array(id, count);
      if (dest != null) {
        if (dest.capacity < count) _destTooShort(id, dest.capacity, count);
        dest.length = count;
        if (_pos + total > _len) return _bad(DecodeStatus.incomplete);
        _readFp64Array(dest, _buf, _pos, count);
        _pos += total;
        return true;
      }
    }
    if (_pos + total > _len) return _bad(DecodeStatus.incomplete);
    _pos += total;
    return true;
  }

  bool _bad(DecodeStatus status) {
    _st = status;
    return false;
  }
}
