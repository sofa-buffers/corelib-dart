import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'utf8.dart';
import 'wire.dart';

/// A push-feed / pull-read consumer of a SofaBuffers stream (CORELIB_PLAN §5.2,
/// §5.3 — the *visitor* pattern, preferred for object-capable languages).
///
/// The decoder calls these methods as fields complete. [shouldRead] is consulted
/// at **header time**, before any payload is consumed: return `false` to skip the
/// field (a length jump — the payload is neither materialized nor UTF-8-validated,
/// CORELIB_PLAN §6.4). For a nested sequence, [onSequenceStart] returns a child
/// visitor to descend, or `null` to skip the whole sub-sequence.
///
/// Booleans arrive via [onUnsigned] (`0`/`1`) — booleans have no wire type
/// (CORELIB_PLAN §4.4); the consumer interprets them. Integer array element width
/// is an API concern, so arrays arrive as 64-bit values.
abstract class MessageVisitor {
  /// Whether to read (materialize) the leaf field, or skip it. Default: read.
  bool shouldRead(int id, int type) => true;

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

  /// A `string` field was materialized and its bytes are valid UTF-8.
  ///
  /// This is a convenience layered on [onStringBytes]: it fires from that
  /// method's **default** implementation, which validates the wire bytes and
  /// transcodes them. A visitor that overrides [onStringBytes] owns the whole
  /// string path and this method is then never called by the decoder.
  void onString(int id, String value) {}

  /// A `string` field was materialized, carrying its **raw wire bytes** —
  /// un-validated and un-transcoded (CORELIB_PLAN §6.4).
  ///
  /// This is the decoder's string path. It fires only for a field that is being
  /// read into a destination: a skipped `string` (an id the consumer declined
  /// via [shouldRead], an id inside a skipped sub-sequence, or any payload the
  /// consumer discards) is a length jump whose bytes are never inspected, so it
  /// never reaches here and is never UTF-8-validated — §6.4's *"skipped fields
  /// are never validated"*, which MESSAGE_SPEC §7.3 extends to a field whose
  /// wire type/subtype contradicts the schema.
  ///
  /// **Schema-bound (generated) consumers override this**, resolve the
  /// destination for `id` *first*, and call `utf8Valid` + `utf8.decode` only
  /// inside a matched destination arm — an unmatched id must return without
  /// validating and without flagging INVALID. A Dart `String` cannot carry
  /// invalid bytes without the lossy U+FFFD substitution §6.4 forbids, so
  /// delivering the raw bytes is the only way a push consumer can honour the
  /// materialize-only rule. Such an override reports a rejected payload through
  /// its own sticky INVALID flag, exactly as it already does for a schema
  /// `maxlen` breach seen in [onFixlenHeader].
  ///
  /// The default implementation preserves the always-strict behaviour of this
  /// port for hand-written visitors: invalid UTF-8 at a materialized position
  /// fails the decode with [DecodeStatus.invalid], and valid bytes are decoded
  /// and forwarded to [onString].
  ///
  /// [bytes] is only valid for the duration of the call — the one-shot decoder
  /// hands out a view onto the input buffer. Copy it to retain it.
  void onStringBytes(int id, Uint8List bytes) {
    // ASCII fast path: a byte < 0x80 is a complete, trivially valid UTF-8
    // sequence, so one scan settles validity *and* the transcode —
    // `String.fromCharCodes` builds the one-byte string directly, skipping both
    // the general validator and the UTF-8 decoder. Field names, ids, tags and
    // most identifiers hit this.
    final n = bytes.length;
    var i = 0;
    while (i < n && bytes[i] < 0x80) {
      i++;
    }
    if (i == n) {
      onString(id, String.fromCharCodes(bytes));
      return;
    }
    if (!utf8Valid(bytes, i)) {
      _stringRejected = true;
      return;
    }
    onString(id, utf8.decode(bytes));
  }

  // Set by the default [onStringBytes] when the payload is not valid UTF-8, and
  // consumed by `_deliverString` below. An override never touches it: a
  // schema-bound consumer carries its own sticky INVALID flag.
  bool _stringRejected = false;

  /// [value] is only valid for the duration of the call — the one-shot decoder
  /// hands out a view onto the input buffer. Copy it to retain it.
  void onBlob(int id, Uint8List value) {}
  void onUnsignedArray(int id, Int64List values) {}
  void onSignedArray(int id, Int64List values) {}
  void onFp32Array(int id, Float32List values) {}
  void onFp64Array(int id, Float64List values) {}

  /// Called **once** per array field, for every array kind, with the wire
  /// element [count] and the element [kind] — *before* any element is consumed
  /// and *before* the truncation check. Fires only for a field being read (never
  /// a skipped one, matching the whole-array callbacks), and never per element.
  ///
  /// **Where it fires** (CORELIB_PLAN §4.8):
  ///
  /// * for an integer array (`arrayUnsigned` / `arraySigned`) — the instant the
  ///   `count` varint is read; there is no second word;
  /// * for a fixlen array (`arrayFixlen`) — after the `fixlen_word` has been read
  ///   *and* validated as a format matter, so [kind] is the real element subtype
  ///   ([ArrayKind.fp32] or [ArrayKind.fp64]), never a collapsed "fixlen".
  ///
  /// That ordering is required, not incidental. A fixlen array whose element
  /// subtype contradicts the declared element type is a **skipped** field
  /// (MESSAGE_SPEC §7.3) and was never this field's value, so its element count
  /// is not this field's count and the schema `count` bound MUST NOT be applied
  /// to it. Only a header whose [kind] matches the declared element type gets the
  /// bound. A message that ends *between* the two words is therefore INCOMPLETE,
  /// not INVALID — the decoder cannot yet know which field it is looking at.
  ///
  /// A schema-bound consumer overrides this to reject `count > N` at the header
  /// — inside the arm that matches the declared [kind]: setting its own sticky
  /// INVALID flag here makes INVALID dominate a truncated tail (MESSAGE_SPEC §5.2
  /// anti-folding), which the post-assembly
  /// [onUnsignedArray]/[onSignedArray]/[onFp32Array]/[onFp64Array] guard cannot —
  /// a truncated array never reaches those. Default: no-op.
  ///
  /// A zero-count fixlen array still carries its `fixlen_word`, so the hook still
  /// fires exactly once with the correct [kind] and `count == 0`.
  void onArrayBegin(int id, ArrayKind kind, int count) {}

  /// The inclusive value range an element of the **integer array** field [id]
  /// may take under the schema, or `null` when the field declares no width
  /// narrower than the 64-bit value domain (`u64`/`i64`, an enum or bitfield
  /// element, or an id this visitor does not declare).
  ///
  /// Asked **once per array field**, at the count word, never per element; the
  /// decoder then applies the range as the elements go past.
  ///
  /// It exists because the whole-array callbacks cannot answer in time. A
  /// declared width is a validity bound (MESSAGE_SPEC §7.1) and §5.2 makes
  /// INVALID dominate INCOMPLETE, so an element already outside its width keeps
  /// the message INVALID however little follows it — but a guard over the
  /// assembled [onSignedArray]/[onUnsignedArray] list only runs for an array
  /// that ARRIVES, and the array in question is precisely one that does not.
  /// Same shape as [onArrayBegin] one level down: only the decoder sees the
  /// element in time, only the schema knows the bound (generator#267, Crucible
  /// F-0043).
  ///
  /// [kind] is the kind the WIRE declares. Return `null` for a kind this field
  /// does not declare: an array whose element kind contradicts the schema is a
  /// skipped field (§7.3) and its elements were never this field's value, so
  /// this field's width must not be measured against them — the rule
  /// [onArrayBegin] states for the count bound, one level down again.
  ///
  /// Return a `const` [ElemRange] to keep this allocation-free. Default: none.
  ElemRange? onArrayElemBound(int id, ArrayKind kind) => null;

  /// The element `count` the **schema** declares for the array field [id], or
  /// `null` when the schema leaves it unbounded (`count:` omitted — MESSAGE_SPEC
  /// §7.2 — or an id/[kind] this visitor does not declare).
  ///
  /// This is how a schema-bound consumer takes the receiver-side cap
  /// ([DecoderLimits.maxArrayCount]) **off** one of its fields. The two are
  /// different kinds of statement (CORELIB_PLAN §6.2.1): a cap is deployment
  /// configuration protecting the receiver from a field the schema leaves
  /// unbounded, and it "MUST NOT be applied to a field the schema already
  /// bounds. There the schema bound governs and its violation is `INVALID`"
  /// (MESSAGE_SPEC §7, §7.1) — §6.3 says the same from the other end:
  /// `LimitExceeded` is "never raised for a field the schema bounds". Only the
  /// schema knows which fields those are, so only the consumer can answer.
  /// Without this the decode of a `count: 10000` array would depend on a
  /// deployment cap of 1000 that was never meant for it.
  ///
  /// Answering is therefore a *swap*, not a waiver: the decoder stops measuring
  /// the field against the cap and measures it against the returned bound
  /// instead, and a wire count past that bound is [DecodeStatus.invalid] — the
  /// outcome §7.1 wants there — decided at the count word, before any element
  /// is consumed and before the allocation.
  ///
  /// [kind] is the kind the WIRE declares. Return `null` for a kind this field
  /// does not declare: such an array is a skipped field (MESSAGE_SPEC §7.3) and
  /// was never this field's value, so this field's `count` must not be measured
  /// against it — and the cap, which covers exactly what no schema bound does,
  /// still applies to it. Same rule as [onArrayBegin] and [onArrayElemBound].
  ///
  /// Asked at most once per array field, and only where the answer can change
  /// an outcome: the decoder consults it just after a configured cap has been
  /// exceeded, never on the path where no cap is set or the count fits. A
  /// decode with no [DecoderLimits] therefore pays nothing for it — there the
  /// schema bound is the consumer's own [onArrayBegin] check, as before.
  /// Default: unbounded.
  int? onArrayCountBound(int id, ArrayKind kind) => null;

  /// Called with a fixlen value's declared byte `length` and `subtype`
  /// ([FixlenType]) the instant its length word is read — *before* the payload
  /// and *before* the truncation check. Fires only for a field being read.
  ///
  /// A schema-bound consumer overrides this to reject `length > maxlen` at the
  /// header (INVALID then dominates a truncated payload, §5.2). For a string the
  /// wire `length` is exactly the UTF-8 byte length, so the check is exact and
  /// lets the generator drop the redundant post-decode length guard. Default:
  /// no-op.
  void onFixlenHeader(int id, int subtype, int length) {}

  /// The `maxlen` the **schema** declares for the `string`/`blob` field [id], or
  /// `null` when the schema leaves it unbounded (`maxlen:` omitted, or an
  /// id/[subtype] this visitor does not declare).
  ///
  /// The fixlen counterpart of [onArrayCountBound], with the same contract:
  /// answering takes the receiver-side cap ([DecoderLimits.maxStringLen] /
  /// [DecoderLimits.maxBlobLen]) off the field and puts the schema bound in its
  /// place, so a length past the bound is [DecodeStatus.invalid] (MESSAGE_SPEC
  /// §7.1) rather than [DecodeStatus.limitExceeded] — which §6.3 forbids for a
  /// field the schema bounds. Decided at the length word, before the payload.
  ///
  /// [subtype] is the subtype the WIRE declares ([FixlenType.string] /
  /// [FixlenType.blob]; the fp32/fp64 subtypes have a fixed 4/8-byte length, so
  /// no cap covers them and this is never asked for one). Return `null` for a
  /// subtype this field does not declare — that is a MESSAGE_SPEC §7.3 skip and
  /// this field's `maxlen` does not govern it.
  ///
  /// Asked at most once per field, and only just after a configured cap has
  /// been exceeded, so a decode with no [DecoderLimits] pays nothing for it.
  /// Default: unbounded.
  int? onFixlenLenBound(int id, int subtype) => null;

  /// A sequence opened. Return a visitor for its children (which follows the
  /// same push/pull contract recursively), or `null` to skip the sub-sequence.
  /// Default: descend, reusing this visitor.
  MessageVisitor? onSequenceStart(int id) => this;

  /// The sequence whose children this visitor received has closed.
  void onSequenceEnd() {}
}

/// The inclusive range an integer array's elements may take under the schema —
/// the answer to [MessageVisitor.onArrayElemBound].
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

/// Hands a materialized `string` payload to [vis] as raw bytes. Returns `false`
/// when the *default* [MessageVisitor.onStringBytes] rejected it as invalid
/// UTF-8; an override signals a rejection through its own sticky flag instead,
/// so this always returns `true` for one.
bool _deliverString(MessageVisitor vis, int id, Uint8List bytes) {
  vis.onStringBytes(id, bytes);
  if (!vis._stringRejected) return true;
  vis._stringRejected = false; // leave the visitor reusable for a fresh decode
  return false;
}

/// Configured receiver-side technical limits (CORELIB_PLAN §6.2.1). These are a
/// deployment **policy**, not schema validity: exceeding one yields
/// [DecodeStatus.limitExceeded], never [DecodeStatus.invalid]. `null` = unbounded.
///
/// They are the backstop for the fields the **schema** leaves unbounded, and
/// only those. §6.2.1: a limit "MUST NOT be applied to a field the schema
/// already bounds. There the schema bound governs and its violation is
/// `INVALID`". A schema-bound consumer says which fields those are through
/// [MessageVisitor.onArrayCountBound] / [MessageVisitor.onFixlenLenBound]; for
/// a field that answers, the declared bound replaces the limit below and a
/// breach of it is [DecodeStatus.invalid].
class DecoderLimits {
  const DecoderLimits({this.maxArrayCount, this.maxStringLen, this.maxBlobLen});
  final int? maxArrayCount;
  final int? maxStringLen;
  final int? maxBlobLen;
}

/// Weighs an array's wire [count] against the receiver-side cap and, where the
/// schema bounds the field, against that bound instead (CORELIB_PLAN §6.2.1,
/// §6.3). Returns the terminal status to fail with, or `null` when the field may
/// proceed.
///
/// Called at the count word — for a fixlen array, at the `fixlen_word` that
/// settles [kind] — i.e. before the allocation the cap exists to prevent, and
/// only for a field being materialized: a skipped field allocates nothing.
/// [MessageVisitor.onArrayCountBound] is asked only once the cap is already
/// exceeded, which is the only place its answer changes an outcome.
DecodeStatus? _arrayCountVerdict(
  MessageVisitor vis,
  DecoderLimits limits,
  int id,
  ArrayKind kind,
  int count,
) {
  final cap = limits.maxArrayCount;
  if (cap == null || count <= cap) return null;
  final bound = vis.onArrayCountBound(id, kind);
  // No schema bound on this field: the cap applies, as a policy rejection.
  if (bound == null) return DecodeStatus.limitExceeded;
  // Schema-bounded: the cap is off this field and the declared bound decides.
  return count > bound ? DecodeStatus.invalid : null;
}

/// The fixlen counterpart of [_arrayCountVerdict], at the `fixlen_word`. Only
/// `string`/`blob` carry a configurable cap — an fp32/fp64 length is fixed at
/// 4/8 bytes by the format and was validated as such above.
DecodeStatus? _fixlenLenVerdict(
  MessageVisitor vis,
  DecoderLimits limits,
  int id,
  int subtype,
  int length,
) {
  final int? cap;
  if (subtype == FixlenType.string) {
    cap = limits.maxStringLen;
  } else if (subtype == FixlenType.blob) {
    cap = limits.maxBlobLen;
  } else {
    return null;
  }
  if (cap == null || length <= cap) return null;
  final bound = vis.onFixlenLenBound(id, subtype);
  if (bound == null) return DecodeStatus.limitExceeded;
  return length > bound ? DecodeStatus.invalid : null;
}

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

/// The empty payload every zero-length `string`/`blob` is delivered as — one
/// object for the whole isolate rather than one per field.
final Uint8List _noBytes = Uint8List(0);

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
void _readFp32Array(Float32List dst, Uint8List src, int srcStart, int count) {
  if (_hostIsLittleEndian) {
    Uint8List.sublistView(dst).setRange(0, count * 4, src, srcStart);
  } else {
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 4);
    for (var i = 0; i < count; i++) {
      dst[i] = bd.getFloat32(i * 4, Endian.little);
    }
  }
}

/// The fp64 twin of [_readFp32Array]: [count] 8-byte little-endian elements out
/// of [src] at [srcStart] into [dst], in bulk where the host layout already
/// matches the wire.
void _readFp64Array(Float64List dst, Uint8List src, int srcStart, int count) {
  if (_hostIsLittleEndian) {
    Uint8List.sublistView(dst).setRange(0, count * 8, src, srcStart);
  } else {
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 8);
    for (var i = 0; i < count; i++) {
      dst[i] = bd.getFloat64(i * 8, Endian.little);
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
/// state machine. The only heap the hot path touches is a per-field carry buffer
/// for a `string`/`blob` payload; a float payload stages in a reusable slot.
class Decoder {
  Decoder(MessageVisitor root, {this.limits = const DecoderLimits()})
    : _vis = root;

  final DecoderLimits limits;

  /// The visitor of the innermost open scope, or `null` while that scope is
  /// being skipped — held directly rather than re-read off the stack, because
  /// every field consults it several times.
  MessageVisitor? _vis;

  /// The *enclosing* scopes' visitors, innermost last; its length is the number
  /// of open sequences. A plain visitor list, not a wrapper object per scope —
  /// the scope carried nothing else, so a nested message no longer allocates one
  /// per `sequence_start`. Empty (and never touched) for a flat message.
  final List<MessageVisitor?> _enclosing = <MessageVisitor?>[];

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
  Uint8List? _payloadBuf;

  // Int-array context.
  int _arrType = 0; // WireType.arrayUnsigned or arraySigned
  int _arrCount = 0;
  int _arrIndex = 0;
  Int64List? _arrInts;
  // The declared element width for the array in flight, asked once at the count
  // word (see [MessageVisitor.onArrayElemBound]) and applied per element below,
  // so the per-element cost is two integer compares and no call.
  ElemRange? _arrElemRange;

  // Fixlen-array context.
  int _arrFixSubtype = 0;
  Float32List? _arrF32;
  Float64List? _arrF64;

  /// Reusable 8-byte staging area for one `fp32`/`fp64` scalar payload, and its
  /// `ByteData` twin — the widest a float payload gets. A float field therefore
  /// allocates nothing: no per-field payload buffer and no per-field typed-data
  /// view (whose construction costs ~300 instructions under Dart AOT, several
  /// times a float read). Per **decoder**, not a shared static, so interleaved
  /// decoders cannot overwrite each other's half-arrived payload.
  ///
  /// `late` so a decode that never sees a float never allocates it.
  late final Uint8List _fscratch = Uint8List(8);
  late final ByteData _fscratchData = ByteData.view(_fscratch.buffer);

  /// Feeds a chunk of raw bytes. Returns the outcome for everything consumed so
  /// far (CORELIB_PLAN §5.2).
  DecodeStatus feed(List<int> data) {
    if (_terminal) return _terminalStatus;
    // Everything below reads bytes through a `Uint8List`: on that type AOT
    // compiles an element read down to a load, where `List<int>` indexing is an
    // interface call per byte, and only there can the bulk moves below reach
    // memcpy and a 64-bit varint load. A caller that hands over some other
    // `List<int>` pays one copy for it — `Uint8List.fromList` truncates to 8
    // bits exactly as the per-byte mask did — and nothing delivered ever
    // aliases a fed chunk either way (CORELIB_PLAN §9.6).
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    final n = chunk.length;
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
          final took = _bulkArrElems(chunk, i, n);
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
  /// as for the byte-wise [_stepPayload], so the value is delivered from one
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
  /// last one goes through [_onArrElem], which owns the completion, so the
  /// array is delivered from exactly one place whether it arrived byte-by-byte
  /// or in a single chunk. It also declines a skipped array, whose elements are
  /// walked rather than materialized.
  int _bulkArrElems(Uint8List data, int from, int end) {
    final out = _arrInts;
    final limit = _arrCount - 1;
    final first = _arrIndex;
    // The run reads a maximal varint at a time, so it needs that much room.
    // (`feed` only calls this with nothing accumulated, `_vn == 0`.)
    if (out == null || first >= limit || end - from < _bulkVarintMin) return 0;
    final signed = _arrType == WireType.arraySigned;
    final packed = _varintRun(
      data,
      ByteData.sublistView(data),
      end,
      from,
      out,
      first,
      limit,
      signed,
    );
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
    if (_state == _sHeader && _vn == 0 && _enclosing.isEmpty) {
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

    switch (type) {
      case WireType.unsigned:
        _read = _decideRead(id, type);
        _state = _sUValue;
        return true;
      case WireType.signed:
        _read = _decideRead(id, type);
        _state = _sSValue;
        return true;
      case WireType.fixlen:
        _read = _decideRead(id, type);
        _state = _sFixWord;
        return true;
      case WireType.arrayUnsigned:
      case WireType.arraySigned:
        _read = _decideRead(id, type);
        _arrType = type;
        _state = _sArrCount;
        return true;
      case WireType.arrayFixlen:
        _read = _decideRead(id, type);
        _state = _sArrFixCount;
        return true;
      case WireType.sequenceStart:
        return _openSequence(id);
      case WireType.sequenceEnd:
        return _closeSequence();
    }
    return _fail(DecodeStatus.invalid);
  }

  // Decide read-vs-skip for a leaf field at header time.
  bool _decideRead(int id, int type) {
    if (_skipDepth > 0) return false;
    final v = _vis;
    if (v == null) return false;
    return v.shouldRead(id, type);
  }

  bool _openSequence(int id) {
    // Open count includes skipped sequences, so COMPLETE waits for them too.
    if (_enclosing.length >= maxDepth) {
      return _fail(DecodeStatus.invalid); // nesting past MAX_DEPTH
    }
    _enclosing.add(_vis);
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
    if (_enclosing.isEmpty) {
      return _fail(DecodeStatus.invalid); // sequence-end with no open sequence
    }
    final closed = _vis;
    _vis = _enclosing.removeLast();
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
    // Header hand-off before truncation can be surfaced: a schema-invalid length
    // set here (via the override's sticky flag) dominates a short payload (§5.2).
    // It also comes BEFORE the receiver-side limit below, so a schema-bound
    // consumer learns of a breach the limit would otherwise short-circuit — the
    // limit is a statement about the receiver's capacity, never about the
    // field's validity (§6.2.1).
    if (_read) {
      _vis!.onFixlenHeader(_fieldId, subtype, length);
      // Receiver-side limit (well-formed bytes → limitExceeded, not INVALID) —
      // unless the schema bounds this field, where the schema bound decides.
      final verdict = _fixlenLenVerdict(
        _vis!,
        limits,
        _fieldId,
        subtype,
        length,
      );
      if (verdict != null) return _fail(verdict);
    }
    _fixSubtype = subtype;
    _payloadTotal = length;
    _payloadPos = 0;
    // A float payload stages in the reusable per-decoder scratch (4/8 bytes,
    // both validated above); only a `string`/`blob`, which is handed to the
    // visitor, needs storage of its own.
    _payloadBuf = !_read || length == 0
        ? null
        : (subtype == FixlenType.fp32 || subtype == FixlenType.fp64
              ? _fscratch
              : Uint8List(length));
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

  /// Delivers a payload that has just become whole, however its bytes arrived —
  /// one byte at a time through [_stepPayload] or in a single move through
  /// [_bulkPayload] — and reopens the field boundary. The single place a fixlen
  /// value or a fixlen array reaches the visitor.
  bool _payloadComplete() {
    if (_state == _sFixPayload) {
      if (!_emitFixlen()) return false;
    } else if (_read) {
      _emitFixArray();
    }
    _state = _sHeader;
    return true;
  }

  bool _emitFixlen() {
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
        // Raw wire bytes go to the destination; validation happens there, never
        // here — this point is only reached for a field being materialized
        // (CORELIB_PLAN §6.4). The default hook validates strictly (no U+FFFD
        // substitution) and only then decodes the now-known-valid bytes.
        if (!_deliverString(_vis!, _fieldId, _payloadBuf ?? _noBytes)) {
          return _fail(DecodeStatus.invalid);
        }
        return true;
      case FixlenType.blob:
        _vis!.onBlob(_fieldId, _payloadBuf ?? _noBytes);
        return true;
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _onArrCount(int count) {
    // ARRAY_MAX is an *unsigned* ceiling on a full u64 count word (§6.2, §4.8),
    // and Dart has no unsigned compare: a count with bit 63 set is a negative
    // int here, so `> arrayMax` alone would let it through. Rejected before any
    // allocation, any `count * length` and any cursor move (§7.2 item 5).
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    // Header hand-off before any element (and thus before truncation) — an
    // over-count set INVALID here dominates a short element tail (§5.2). An
    // integer array carries no second word, so this is already the point at
    // which the element kind is fully known (§4.8). It also precedes the
    // receiver-side limit, which must not short-circuit a schema bound (§6.2.1).
    if (_read) {
      final kind = _arrType == WireType.arraySigned
          ? ArrayKind.signed
          : ArrayKind.unsigned;
      _vis!.onArrayBegin(_fieldId, kind, count);
      final verdict = _arrayCountVerdict(_vis!, limits, _fieldId, kind, count);
      if (verdict != null) return _fail(verdict);
      // Asked once, here, for the same reason onArrayBegin fires here: this is
      // where the field is fully identified and no element has been consumed.
      _arrElemRange = _vis!.onArrayElemBound(_fieldId, kind);
    } else {
      _arrElemRange = null;
    }
    _arrCount = count;
    _arrIndex = 0;
    _arrInts = _read ? Int64List(count) : null;
    if (count == 0) {
      if (_read) _emitIntArray();
      _state = _sHeader;
      return true;
    }
    _state = _sArrElem;
    return true;
  }

  bool _onArrElem(int raw) {
    if (_read) {
      final signed = _arrType == WireType.arraySigned;
      final v = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
      // The declared width, applied AT the element (§7.1). The whole-array
      // callback below is too late for an array that never completes, and §5.2
      // makes this element's INVALID outrank that truncation.
      final r = _arrElemRange;
      if (r != null &&
          (signed ? (v < r.min || v > r.max) : (v < 0 || v > r.max))) {
        return _fail(DecodeStatus.invalid);
      }
      _arrInts![_arrIndex] = v;
    }
    _arrIndex++;
    if (_arrIndex < _arrCount) return true;
    if (_read) _emitIntArray();
    _state = _sHeader;
    return true;
  }

  void _emitIntArray() {
    final v = _arrInts!;
    if (_arrType == WireType.arraySigned) {
      _vis!.onSignedArray(_fieldId, v);
    } else {
      _vis!.onUnsignedArray(_fieldId, v);
    }
  }

  bool _onArrFixCount(int count) {
    // Unsigned ceiling — see [_onArrCount]. This one also guards the
    // `_arrCount * length` below, which a bit-63 count would wrap.
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    // NO header hand-off here: for a fixlen array the element subtype lives in
    // the *next* word, and §4.8 requires it to be decided before the field is
    // offered (see [MessageVisitor.onArrayBegin]). The hook fires in
    // [_onArrFixWord], and so does the receiver-side count limit — deciding
    // whether the SCHEMA bounds this count needs the element kind, for the
    // reason the hook does (a mismatched subtype is another field's shape,
    // §7.3). Only the format ceiling above belongs to the bare count word; the
    // limit still lands before the payload allocation it prevents (§6.2.1).
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
    // The subtype is now known and legal, so this is the §4.8 point at which the
    // field can be offered: the hook carries the real element kind, and still
    // fires before the payload (thus before truncation), so an over-count set
    // INVALID here dominates a short tail (§5.2). It also fires for count == 0.
    if (_read) {
      final kind = subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64;
      _vis!.onArrayBegin(_fieldId, kind, _arrCount);
      final verdict = _arrayCountVerdict(
        _vis!,
        limits,
        _fieldId,
        kind,
        _arrCount,
      );
      if (verdict != null) return _fail(verdict);
    }
    _arrFixSubtype = subtype;
    _payloadTotal = _arrCount * length;
    _payloadPos = 0;
    if (_read) {
      // ONE allocation for the payload, not two: the result list is allocated
      // here and the arriving wire bytes are staged directly in *its* storage,
      // because a fixlen array's payload already is that list's little-endian
      // byte image. Peak memory is therefore the array itself, and
      // [_emitFixArray] has nothing left to copy or convert — the streaming
      // path costs what the one-shot path costs. A (hypothetical) big-endian
      // host cannot alias the two and keeps a separate staging buffer plus the
      // element-wise conversion in [_readFp32Array]/[_readFp64Array].
      final TypedData out;
      if (subtype == FixlenType.fp32) {
        final list = Float32List(_arrCount);
        _arrF32 = list;
        _arrF64 = null;
        out = list;
      } else {
        final list = Float64List(_arrCount);
        _arrF64 = list;
        _arrF32 = null;
        out = list;
      }
      _payloadBuf = _hostIsLittleEndian
          ? Uint8List.sublistView(out)
          : Uint8List(_payloadTotal);
    }
    _state = _sArrFixPayload;
    return _payloadTotal == 0 ? _payloadComplete() : true;
  }

  void _emitFixArray() {
    // Where the payload was staged in the result list's own bytes (the rule —
    // see [_onArrFixWord]) the elements are already there, bit-exact; only a
    // big-endian host still has a staging buffer to convert out of.
    if (_arrFixSubtype == FixlenType.fp32) {
      final out = _arrF32!;
      if (!_hostIsLittleEndian) _readFp32Array(out, _payloadBuf!, 0, _arrCount);
      _vis!.onFp32Array(_fieldId, out);
    } else {
      final out = _arrF64!;
      if (!_hostIsLittleEndian) _readFp64Array(out, _payloadBuf!, 0, _arrCount);
      _vis!.onFp64Array(_fieldId, out);
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
  static DecodeStatus decode(
    List<int> bytes,
    MessageVisitor visitor, {
    DecoderLimits limits = const DecoderLimits(),
  }) {
    final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _ContiguousDecoder(buf, limits).run(visitor);
  }
}

/// Fast one-shot decoder for a fully-contiguous buffer. Advances an index over
/// the bytes (the protobuf-style "advance a pointer over a contiguous buffer"),
/// with no per-byte state machine and no `Decoder`/frame allocation. Recursive
/// descent over sequences. Semantics — decode outcomes, INVALID-over-INCOMPLETE
/// precedence, skip-without-validation, receiver limits — match [Decoder.feed]
/// exactly (both are covered by the same conformance vectors).
class _ContiguousDecoder {
  _ContiguousDecoder(this._buf, this._limits) : _len = _buf.length;

  final Uint8List _buf;
  final DecoderLimits _limits;
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
    _walk(root, 0);
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
      switch (type) {
        case WireType.unsigned:
          final readU = vis != null && vis.shouldRead(id, type);
          final val = _uvarint();
          if (_st != DecodeStatus.complete) return;
          if (readU) vis.onUnsigned(id, val);
          break;
        case WireType.signed:
          final readS = vis != null && vis.shouldRead(id, type);
          final raw = _uvarint();
          if (_st != DecodeStatus.complete) return;
          if (readS) vis.onSigned(id, (raw >>> 1) ^ -(raw & 1));
          break;
        case WireType.fixlen:
          if (!_fixlen(vis, id, vis != null && vis.shouldRead(id, type))) {
            return;
          }
          break;
        case WireType.arrayUnsigned:
        case WireType.arraySigned:
          if (!_intArray(
            vis,
            id,
            type,
            vis != null && vis.shouldRead(id, type),
          )) {
            return;
          }
          break;
        case WireType.arrayFixlen:
          if (!_fixArray(vis, id, vis != null && vis.shouldRead(id, type))) {
            return;
          }
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

  bool _fixlen(MessageVisitor? vis, int id, bool read) {
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
    // Header hand-off before the truncation check, so a schema-invalid length
    // (flagged in the override) dominates a short payload (§5.2) — and before
    // the receiver-side limit, which must not short-circuit it (§6.2.1). See
    // [_fixlenLenVerdict] for the limit-vs-schema-bound split.
    if (read) {
      vis!.onFixlenHeader(id, subtype, length);
      final verdict = _fixlenLenVerdict(vis, _limits, id, subtype, length);
      if (verdict != null) return _bad(verdict);
    }
    if (_pos + length > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += length;
    if (read) {
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
            // See _emitFixlen: NaN goes out as raw bits so a signaling NaN's
            // is-quiet bit is not set by widening to a double (§4.6).
            if (v.isNaN) {
              vis!.onFp32Bits(id, _scratchData.getUint32(0, Endian.little));
            } else {
              vis!.onFp32(id, v);
            }
            break;
          }
        case FixlenType.fp64:
          // `setRange` between two `Uint8List`s hits a bulk copy and measured
          // cheaper than eight indexed stores at this width.
          _scratchBytes.setRange(0, 8, _buf, start);
          vis!.onFp64(id, _scratchData.getFloat64(0, Endian.little));
          break;
        case FixlenType.string:
          // See _emitFixlen: the destination validates, the decoder does not.
          // `Uint8List.view` is a little cheaper than `sublistView`, which adds
          // a generic range check on top of the same work.
          final view = Uint8List.view(
            _buf.buffer,
            _buf.offsetInBytes + start,
            length,
          );
          if (!_deliverString(vis!, id, view)) {
            return _bad(DecodeStatus.invalid);
          }
          break;
        case FixlenType.blob:
          vis!.onBlob(
            id,
            Uint8List.view(_buf.buffer, _buf.offsetInBytes + start, length),
          );
          break;
      }
    }
    return true;
  }

  bool _intArray(MessageVisitor? vis, int id, int type, bool read) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling: the count word is a full u64, so a count with bit 63
    // set lands as a negative Dart int and `> arrayMax` alone misses it — the
    // element loop would then either allocate an impossible `Int64List` or, on
    // the skip path, run zero times and accept a bogus empty array (§6.2, §4.8).
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    final signed = type == WireType.arraySigned;
    // Header hand-off before the element loop (before truncation) — over-count
    // flagged here dominates a short tail (§5.2). An integer array carries no
    // second word, so the element kind is already fully known here (§4.8). The
    // receiver-side limit comes after the hook and yields to a schema bound
    // (§6.2.1) — see [_arrayCountVerdict].
    ElemRange? range;
    if (read) {
      final kind = signed ? ArrayKind.signed : ArrayKind.unsigned;
      vis!.onArrayBegin(id, kind, count);
      final verdict = _arrayCountVerdict(vis, _limits, id, kind, count);
      if (verdict != null) return _bad(verdict);
      range = vis.onArrayElemBound(id, kind);
    }
    if (!read) {
      // Skipping: walk the element varints without materializing anything.
      for (var i = 0; i < count; i++) {
        _uvarint();
        if (_st != DecodeStatus.complete) return false;
      }
      return true;
    }
    // Size the result from the bytes actually in hand, not from the wire count.
    // Every element costs at least one varint byte, so a count above the bytes
    // that remain has already been refuted by the input: at most `avail`
    // elements can ever be written, and the array is bound for INCOMPLETE. The
    // allocation is therefore capped at the input's own size — a 6-byte message
    // claiming ARRAY_MAX elements would otherwise ask the VM for 17 GB (§7.2
    // item 5: a well-defined outcome, never a crash; §6.2.1: decide *before*
    // the allocation). The decode itself still runs over the prefix, so an
    // element outside its declared width keeps outranking the truncation (§5.2)
    // instead of being lost to an early bail-out.
    final avail = _len - _pos;
    final out = Int64List(count <= avail ? count : avail);
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
        // The array does not complete, so neither whole-array callback below
        // fires and the consumer's own width guard never runs. The elements
        // already decoded are on the wire all the same, and §5.2 makes one
        // outside its declared width outrank this truncation (generator#267).
        // Checked HERE rather than in the loops above so the word-wise hot path
        // stays a pure decode: the prefix is walked only when the array fails.
        if (range != null && _elemOutOfRange(out, 0, i, signed, range)) {
          return _bad(DecodeStatus.invalid);
        }
        return false;
      }
      out[i] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
    }
    // ... and the same sweep once the array HAS arrived. An element outside its
    // declared width is INVALID wherever it sits (§7.1), and the whole-array
    // callbacks below return `void`, so a visitor that answered
    // [MessageVisitor.onArrayElemBound] has no channel left to reject through:
    // leaving this case to them contradicted the hook's own contract ("the
    // decoder then applies the range as the elements go past") and made this
    // surface disagree with [Decoder.feed], which checks at every element (#38).
    // Still off the hot path in the sense that matters: one pass over an
    // in-cache `Int64List`, and only for a field that declares a narrowed width.
    if (range != null && _elemOutOfRange(out, 0, count, signed, range)) {
      return _bad(DecodeStatus.invalid);
    }
    if (signed) {
      vis!.onSignedArray(id, out);
    } else {
      vis!.onUnsignedArray(id, out);
    }
    return true;
  }

  bool _fixArray(MessageVisitor? vis, int id, bool read) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling — see [_intArray]. It also keeps `count * length` below
    // from wrapping, which would move `_pos` backwards.
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    // NO header hand-off here: §4.8 has the element subtype decided first, so the
    // hook waits for the word below (see [MessageVisitor.onArrayBegin]). EOF
    // between the two words is therefore INCOMPLETE, not INVALID. The
    // receiver-side count limit waits with it — whether the SCHEMA bounds this
    // count is a question about the element kind (§7.3) — and still lands before
    // the payload allocation it prevents.
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
    // Subtype known and legal: offer the field now, carrying the real element
    // kind, still before the payload (thus before truncation) — over-count
    // flagged here dominates a short tail (§5.2). Fires for count == 0 too.
    if (read) {
      final kind = subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64;
      vis!.onArrayBegin(id, kind, count);
      final verdict = _arrayCountVerdict(vis, _limits, id, kind, count);
      if (verdict != null) return _bad(verdict);
    }
    final total = count * length;
    if (_pos + total > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += total;
    if (read) {
      if (subtype == FixlenType.fp32) {
        final o = Float32List(count);
        _readFp32Array(o, _buf, start, count);
        vis!.onFp32Array(id, o);
      } else {
        final o = Float64List(count);
        _readFp64Array(o, _buf, start, count);
        vis!.onFp64Array(id, o);
      }
    }
    return true;
  }

  bool _bad(DecodeStatus status) {
    _st = status;
    return false;
  }
}
