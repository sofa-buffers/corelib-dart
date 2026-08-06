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
class DecoderLimits {
  const DecoderLimits({this.maxArrayCount, this.maxStringLen, this.maxBlobLen});
  final int? maxArrayCount;
  final int? maxStringLen;
  final int? maxBlobLen;
}

// Internal decoder states.
const int _sHeader = 0;
const int _sUValue = 1; // unsigned value varint
const int _sSValue = 2; // signed value varint
const int _sFixWord = 3;
const int _sFixPayload = 4;
const int _sArrCount = 5; // count for int arrays (u/s)
const int _sArrElem = 6; // per-element varint for int arrays
const int _sArrFixCount = 7;
const int _sArrFixWord = 8;
const int _sArrFixPayload = 9;

class _Frame {
  _Frame(this.visitor);
  // null visitor => this scope is being skipped.
  final MessageVisitor? visitor;
}

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

/// Fills [dst] with [count] fp32 elements from little-endian wire bytes in [src]
/// starting at [srcStart], preserving each element's raw 32-bit pattern
/// (CORELIB_PLAN §4.6 — a signaling NaN must not be quieted). On a little-endian
/// host (every platform Dart targets) this is a single bulk byte copy: bit-exact
/// *and* faster than a per-element float read. A big-endian host falls back to
/// endian-swapping element reads — which cannot preserve an sNaN, but no such
/// host exists in practice.
void _readFp32Array(Float32List dst, Uint8List src, int srcStart, int count) {
  if (Endian.host == Endian.little) {
    Uint8List.sublistView(dst).setRange(0, count * 4, src, srcStart);
  } else {
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 4);
    for (var i = 0; i < count; i++) {
      dst[i] = bd.getFloat32(i * 4, Endian.little);
    }
  }
}

/// Streaming SofaBuffers decoder (CORELIB_PLAN §5.2).
///
/// Feed arbitrarily small chunks via [feed]; the state machine suspends and
/// resumes at **any** byte boundary. Each [feed] (and the one-shot [decode])
/// returns the three-valued [DecodeStatus] describing the bytes consumed so far —
/// there is **no** finalize step, and `incomplete` is never auto-promoted to an
/// error. The only heap the hot path touches is a per-field carry buffer for a
/// payload that straddles a chunk boundary.
class Decoder {
  Decoder(MessageVisitor root, {this.limits = const DecoderLimits()})
    : _frames = <_Frame>[_Frame(root)];

  final DecoderLimits limits;
  final List<_Frame> _frames;

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

  MessageVisitor? get _topVisitor => _frames.last.visitor;

  /// Feeds a chunk of raw bytes. Returns the outcome for everything consumed so
  /// far (CORELIB_PLAN §5.2).
  DecodeStatus feed(List<int> data) {
    if (_terminal) return _terminalStatus;
    final n = data.length;
    // `List<int>` indexing is an interface call per byte; promoting the common
    // `Uint8List` case lets AOT compile the read down to a load. The elements
    // are already 0..255 there, so the mask is a no-op and is dropped.
    if (data is Uint8List) {
      for (var i = 0; i < n; i++) {
        if (!_step(data[i])) {
          _terminal = true;
          return _terminalStatus;
        }
      }
      return _boundaryStatus();
    }
    for (var i = 0; i < n; i++) {
      if (!_step(data[i] & 0xFF)) {
        _terminal = true;
        return _terminalStatus;
      }
    }
    return _boundaryStatus();
  }

  DecodeStatus _boundaryStatus() {
    // COMPLETE only at a field boundary with no open sequence (CORELIB_PLAN
    // §5.2 framing invariant).
    if (_state == _sHeader && _vn == 0 && _frames.length == 1) {
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
  bool _step(int b) {
    switch (_state) {
      case _sHeader:
        return _stepHeader(b);
      case _sUValue:
        {
          final r = _vfeed(b);
          if (r < 0) return _fail(DecodeStatus.invalid);
          if (r == 0) return true;
          final value = _v;
          _vreset();
          _state = _sHeader;
          if (_read) _topVisitor!.onUnsigned(_fieldId, value);
          return true;
        }
      case _sSValue:
        {
          final r = _vfeed(b);
          if (r < 0) return _fail(DecodeStatus.invalid);
          if (r == 0) return true;
          final raw = _v;
          _vreset();
          _state = _sHeader;
          if (_read) _topVisitor!.onSigned(_fieldId, (raw >>> 1) ^ -(raw & 1));
          return true;
        }
      case _sFixWord:
        return _stepFixWord(b);
      case _sFixPayload:
        return _stepFixPayload(b);
      case _sArrCount:
        return _stepArrCount(b);
      case _sArrElem:
        return _stepArrElem(b);
      case _sArrFixCount:
        return _stepArrFixCount(b);
      case _sArrFixWord:
        return _stepArrFixWord(b);
      case _sArrFixPayload:
        return _stepArrFixPayload(b);
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _stepHeader(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final header = _v;
    _vreset();
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
    final v = _topVisitor;
    if (v == null) return false;
    return v.shouldRead(id, type);
  }

  bool _openSequence(int id) {
    // Open count includes skipped sequences, so COMPLETE waits for them too.
    if (_frames.length - 1 >= maxDepth) {
      return _fail(DecodeStatus.invalid); // nesting past MAX_DEPTH
    }
    if (_skipDepth > 0) {
      _skipDepth++;
      _frames.add(_Frame(null));
      return true;
    }
    final child = _topVisitor!.onSequenceStart(id);
    if (child == null) {
      _skipDepth = 1;
      _frames.add(_Frame(null));
    } else {
      _frames.add(_Frame(child));
    }
    return true;
  }

  bool _closeSequence() {
    if (_frames.length == 1) {
      return _fail(DecodeStatus.invalid); // sequence-end with no open sequence
    }
    final frame = _frames.removeLast();
    if (_skipDepth > 0) {
      _skipDepth--;
    } else {
      frame.visitor?.onSequenceEnd();
    }
    return true;
  }

  bool _stepFixWord(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final word = _v;
    _vreset();
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
    // Receiver-side limits (well-formed bytes → limitExceeded, not INVALID).
    if (_read) {
      if (subtype == FixlenType.string &&
          limits.maxStringLen != null &&
          length > limits.maxStringLen!) {
        return _fail(DecodeStatus.limitExceeded);
      }
      if (subtype == FixlenType.blob &&
          limits.maxBlobLen != null &&
          length > limits.maxBlobLen!) {
        return _fail(DecodeStatus.limitExceeded);
      }
    }
    // Header hand-off before truncation can be surfaced: a schema-invalid length
    // set here (via the override's sticky flag) dominates a short payload (§5.2).
    if (_read) _topVisitor!.onFixlenHeader(_fieldId, subtype, length);
    _fixSubtype = subtype;
    _payloadTotal = length;
    _payloadPos = 0;
    _payloadBuf = _read && length > 0 ? Uint8List(length) : null;
    if (length == 0) {
      _emitFixlen();
      _state = _sHeader;
      return true;
    }
    _state = _sFixPayload;
    return true;
  }

  bool _stepFixPayload(int b) {
    if (_read) _payloadBuf![_payloadPos] = b;
    _payloadPos++;
    if (_payloadPos < _payloadTotal) return true;
    if (!_emitFixlen()) return false;
    _state = _sHeader;
    return true;
  }

  bool _emitFixlen() {
    if (!_read) return true;
    final buf = _payloadBuf ?? Uint8List(0);
    switch (_fixSubtype) {
      case FixlenType.fp32:
        {
          final view = ByteData.sublistView(buf);
          final v = view.getFloat32(0, Endian.little);
          // Non-NaN widens to a double and back losslessly (hot path). A NaN can
          // carry a payload/signaling bit the double would quiet, so re-read the
          // raw wire bits and deliver those (§4.6: never normalize).
          if (v.isNaN) {
            _topVisitor!.onFp32Bits(_fieldId, view.getUint32(0, Endian.little));
          } else {
            _topVisitor!.onFp32(_fieldId, v);
          }
          return true;
        }
      case FixlenType.fp64:
        _topVisitor!.onFp64(
          _fieldId,
          ByteData.sublistView(buf).getFloat64(0, Endian.little),
        );
        return true;
      case FixlenType.string:
        // Raw wire bytes go to the destination; validation happens there, never
        // here — this point is only reached for a field being materialized
        // (CORELIB_PLAN §6.4). The default hook validates strictly (no U+FFFD
        // substitution) and only then decodes the now-known-valid bytes.
        if (!_deliverString(_topVisitor!, _fieldId, buf)) {
          return _fail(DecodeStatus.invalid);
        }
        return true;
      case FixlenType.blob:
        _topVisitor!.onBlob(_fieldId, buf);
        return true;
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _stepArrCount(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final count = _v;
    _vreset();
    if (count > arrayMax) return _fail(DecodeStatus.invalid);
    if (_read &&
        limits.maxArrayCount != null &&
        count > limits.maxArrayCount!) {
      return _fail(DecodeStatus.limitExceeded);
    }
    // Header hand-off before any element (and thus before truncation) — an
    // over-count set INVALID here dominates a short element tail (§5.2). An
    // integer array carries no second word, so this is already the point at
    // which the element kind is fully known (§4.8).
    if (_read) {
      final kind = _arrType == WireType.arraySigned
          ? ArrayKind.signed
          : ArrayKind.unsigned;
      _topVisitor!.onArrayBegin(_fieldId, kind, count);
      // Asked once, here, for the same reason onArrayBegin fires here: this is
      // where the field is fully identified and no element has been consumed.
      _arrElemRange = _topVisitor!.onArrayElemBound(_fieldId, kind);
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

  bool _stepArrElem(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final raw = _v;
    _vreset();
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
      _topVisitor!.onSignedArray(_fieldId, v);
    } else {
      _topVisitor!.onUnsignedArray(_fieldId, v);
    }
  }

  bool _stepArrFixCount(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final count = _v;
    _vreset();
    if (count > arrayMax) return _fail(DecodeStatus.invalid);
    if (_read &&
        limits.maxArrayCount != null &&
        count > limits.maxArrayCount!) {
      return _fail(DecodeStatus.limitExceeded);
    }
    // NO header hand-off here: for a fixlen array the element subtype lives in
    // the *next* word, and §4.8 requires it to be decided before the field is
    // offered (see [MessageVisitor.onArrayBegin]). The hook fires in
    // [_stepArrFixWord]. The format ceiling and the receiver policy limit above
    // stay on the count word — they are not schema bounds.
    _arrCount = count;
    _arrIndex = 0;
    _state = _sArrFixWord;
    return true;
  }

  bool _stepArrFixWord(int b) {
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final word = _v;
    _vreset();
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
      _topVisitor!.onArrayBegin(
        _fieldId,
        subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64,
        _arrCount,
      );
    }
    _arrFixSubtype = subtype;
    _payloadTotal = _arrCount * length;
    _payloadPos = 0;
    if (_read) {
      _payloadBuf = _payloadTotal > 0 ? Uint8List(_payloadTotal) : Uint8List(0);
      _arrF32 = subtype == FixlenType.fp32 ? Float32List(_arrCount) : null;
      _arrF64 = subtype == FixlenType.fp64 ? Float64List(_arrCount) : null;
    }
    if (_payloadTotal == 0) {
      if (_read) _emitFixArray();
      _state = _sHeader;
      return true;
    }
    _state = _sArrFixPayload;
    return true;
  }

  bool _stepArrFixPayload(int b) {
    if (_read) _payloadBuf![_payloadPos] = b;
    _payloadPos++;
    if (_payloadPos < _payloadTotal) return true;
    if (_read) _emitFixArray();
    _state = _sHeader;
    return true;
  }

  void _emitFixArray() {
    if (_arrFixSubtype == FixlenType.fp32) {
      final out = _arrF32!;
      _readFp32Array(out, _payloadBuf!, 0, _arrCount);
      _topVisitor!.onFp32Array(_fieldId, out);
    } else {
      final bd = ByteData.sublistView(_payloadBuf!);
      final out = _arrF64!;
      for (var i = 0; i < _arrCount; i++) {
        out[i] = bd.getFloat64(i * 8, Endian.little);
      }
      _topVisitor!.onFp64Array(_fieldId, out);
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
    if (read) {
      if (subtype == FixlenType.string &&
          _limits.maxStringLen != null &&
          length > _limits.maxStringLen!) {
        return _bad(DecodeStatus.limitExceeded);
      }
      if (subtype == FixlenType.blob &&
          _limits.maxBlobLen != null &&
          length > _limits.maxBlobLen!) {
        return _bad(DecodeStatus.limitExceeded);
      }
    }
    // Header hand-off before the truncation check, so a schema-invalid length
    // (flagged in the override) dominates a short payload (§5.2).
    if (read) vis!.onFixlenHeader(id, subtype, length);
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
    if (count > arrayMax) return _bad(DecodeStatus.invalid);
    if (read &&
        _limits.maxArrayCount != null &&
        count > _limits.maxArrayCount!) {
      return _bad(DecodeStatus.limitExceeded);
    }
    final signed = type == WireType.arraySigned;
    // Header hand-off before the element loop (before truncation) — over-count
    // flagged here dominates a short tail (§5.2). An integer array carries no
    // second word, so the element kind is already fully known here (§4.8).
    ElemRange? range;
    if (read) {
      final kind = signed ? ArrayKind.signed : ArrayKind.unsigned;
      vis!.onArrayBegin(id, kind, count);
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
    final out = Int64List(count);
    // Hot loop. The word-wise varint is inlined here with the read position and
    // the buffer held in locals, so the whole array costs no per-element field
    // reload, no `_st` re-check and no null check. (An earlier attempt at
    // hand-inlining the *byte-wise* reader measured slower — the win here is the
    // 64-bit load, not the inlining.)
    final buf = _buf;
    final len = _len;
    var p = _pos;
    var i = 0;
    // Word-wise element loop. Entered only when a maximal varint is in bounds,
    // which is also the condition under which building the [_bd] view pays for
    // itself — a short array near the end of the buffer skips it entirely and
    // takes the scalar reader below.
    if (p + 10 <= len) {
      final bd = _bd;
      while (i < count && p + 10 <= len) {
        int raw;
        // One 64-bit load serves every length. The short-varint cases are
        // derived from that same word rather than from extra byte loads (a
        // bounds-checked `Uint8List` read costs ~8 instructions), and the
        // all-continuation case is tested first because it is the one that
        // cannot be short-circuited.
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
            p += 10;
            if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) {
              _pos = p;
              return _bad(DecodeStatus.invalid);
            }
            raw |= (last & 0x7f) << 63;
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
    }
    _pos = p;
    // Tail: the last elements, where a 64-bit load would overrun the buffer.
    // Also the path that reports INCOMPLETE on a short element run.
    for (; i < count; i++) {
      final raw = _uvarint();
      if (_st != DecodeStatus.complete) {
        // The array does not complete, so neither whole-array callback below
        // fires and the consumer's own width guard never runs. The elements
        // already decoded are on the wire all the same, and §5.2 makes one
        // outside its declared width outrank this truncation (generator#267).
        // Checked HERE rather than in the loops above so the word-wise hot path
        // stays a pure decode: the prefix is walked only when the array fails.
        if (range != null && _elemOutOfRange(out, i, signed, range)) {
          return _bad(DecodeStatus.invalid);
        }
        return false;
      }
      out[i] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
    }
    if (signed) {
      vis!.onSignedArray(id, out);
    } else {
      vis!.onUnsignedArray(id, out);
    }
    return true;
  }

  /// Whether any of `out[0..n)` falls outside [range]. See [ElemRange] for why
  /// the unsigned arm also rejects a negative: Dart has no unsigned compare, and
  /// a wire value above 2^63 is above every bound that can exist here.
  static bool _elemOutOfRange(
    Int64List out,
    int n,
    bool signed,
    ElemRange range,
  ) {
    for (var i = 0; i < n; i++) {
      final v = out[i];
      if (signed
          ? (v < range.min || v > range.max)
          : (v < 0 || v > range.max)) {
        return true;
      }
    }
    return false;
  }

  bool _fixArray(MessageVisitor? vis, int id, bool read) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    if (count > arrayMax) return _bad(DecodeStatus.invalid);
    if (read &&
        _limits.maxArrayCount != null &&
        count > _limits.maxArrayCount!) {
      return _bad(DecodeStatus.limitExceeded);
    }
    // NO header hand-off here: §4.8 has the element subtype decided first, so the
    // hook waits for the word below (see [MessageVisitor.onArrayBegin]). EOF
    // between the two words is therefore INCOMPLETE, not INVALID.
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
      vis!.onArrayBegin(
        id,
        subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64,
        count,
      );
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
        final bd = _bd;
        final o = Float64List(count);
        for (var i = 0; i < count; i++) {
          o[i] = bd.getFloat64(start + i * 8, Endian.little);
        }
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
