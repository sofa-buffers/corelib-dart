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
  void onString(int id, String value) {}
  void onBlob(int id, Uint8List value) {}
  void onUnsignedArray(int id, Int64List values) {}
  void onSignedArray(int id, Int64List values) {}
  void onFp32Array(int id, Float32List values) {}
  void onFp64Array(int id, Float64List values) {}

  /// A sequence opened. Return a visitor for its children (which follows the
  /// same push/pull contract recursively), or `null` to skip the sub-sequence.
  /// Default: descend, reusing this visitor.
  MessageVisitor? onSequenceStart(int id) => this;

  /// The sequence whose children this visitor received has closed.
  void onSequenceEnd() {}
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
        // Validate first (strict, no U+FFFD substitution); only then decode the
        // now-known-valid bytes (CORELIB_PLAN §6.4).
        if (!utf8Valid(buf)) return _fail(DecodeStatus.invalid);
        _topVisitor!.onString(_fieldId, utf8.decode(buf));
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
      _arrInts![_arrIndex] = _arrType == WireType.arraySigned
          ? (raw >>> 1) ^ -(raw & 1)
          : raw;
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
  // `complete` doubles as the "still ok" sentinel while walking.
  DecodeStatus _st = DecodeStatus.complete;

  DecodeStatus run(MessageVisitor root) {
    _walk(root, 0);
    return _st;
  }

  // Reads an unsigned LEB128 varint. On end-of-buffer sets INCOMPLETE; on an
  // overlong (>64-bit) varint sets INVALID. Value valid only when `_st` stays
  // `complete`.
  int _uvarint() {
    // Hoist fields into locals (registers) for the hot loop, and keep the
    // overflow guard out of the common per-byte path: bytes 1..9 (shift ≤ 56)
    // can never overflow, so only the 10th byte (shift == 63) is checked.
    final buf = _buf;
    final len = _len;
    var p = _pos;
    var v = 0;
    var shift = 0;
    while (true) {
      if (p >= len) {
        _pos = p;
        _st = DecodeStatus.incomplete;
        return 0;
      }
      final b = buf[p++];
      v |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        _pos = p;
        return v;
      }
      shift += 7;
      if (shift == 63) {
        // The 10th byte may set only bit 63 and must terminate the varint.
        if (p >= len) {
          _pos = p;
          _st = DecodeStatus.incomplete;
          return 0;
        }
        final last = buf[p++];
        _pos = p;
        if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) {
          _st = DecodeStatus.invalid;
          return 0;
        }
        return v | ((last & 0x7f) << 63);
      }
    }
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
    if (_pos + length > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += length;
    if (read) {
      switch (subtype) {
        case FixlenType.fp32:
          {
            final view = ByteData.sublistView(_buf, start, start + 4);
            final v = view.getFloat32(0, Endian.little);
            // See _emitFixlen: NaN goes out as raw bits so a signaling NaN's
            // is-quiet bit is not set by widening to a double (§4.6).
            if (v.isNaN) {
              vis!.onFp32Bits(id, view.getUint32(0, Endian.little));
            } else {
              vis!.onFp32(id, v);
            }
            break;
          }
        case FixlenType.fp64:
          vis!.onFp64(
            id,
            ByteData.sublistView(
              _buf,
              start,
              start + 8,
            ).getFloat64(0, Endian.little),
          );
          break;
        case FixlenType.string:
          final view = Uint8List.sublistView(_buf, start, start + length);
          if (!utf8Valid(view)) return _bad(DecodeStatus.invalid);
          vis!.onString(id, utf8.decode(view));
          break;
        case FixlenType.blob:
          vis!.onBlob(id, Uint8List.sublistView(_buf, start, start + length));
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
    final out = read ? Int64List(count) : null;
    // Note: hand-inlining the varint read here measured *slower* under AOT — the
    // compiler inlines `_uvarint` better than a manual copy — so keep the call.
    for (var i = 0; i < count; i++) {
      final raw = _uvarint();
      if (_st != DecodeStatus.complete) return false;
      if (read) out![i] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
    }
    if (read) {
      if (signed) {
        vis!.onSignedArray(id, out!);
      } else {
        vis!.onUnsignedArray(id, out!);
      }
    }
    return true;
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
        final bd = ByteData.sublistView(_buf, start, start + total);
        final o = Float64List(count);
        for (var i = 0; i < count; i++) {
          o[i] = bd.getFloat64(i * 8, Endian.little);
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
