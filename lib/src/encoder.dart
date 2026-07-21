import 'dart:typed_data';

import 'utf8.dart';
import 'wire.dart';

/// A flush/drain callback (CORELIB_PLAN §5.1). Receives a **view** of the newly
/// filled bytes; the encoder reuses its buffer immediately afterwards, so a
/// callback that keeps the data must copy it. The view is only valid for the
/// duration of the call.
typedef FlushCallback = void Function(Uint8List chunk);

/// Streaming SofaBuffers encoder (CORELIB_PLAN §5.1, §6).
///
/// Writes into a fixed output buffer and calls [FlushCallback] whenever the
/// buffer fills (or on explicit [flush]). The buffer can be far smaller than the
/// message. Supports a start [offset] (leave room for a framing header) and a
/// mid-stream buffer swap via [installBuffer].
///
/// The hot path performs no heap allocation: scalars, headers and array elements
/// are written straight into the caller-owned buffer.
class Encoder {
  Encoder(
    this._flush, {
    Uint8List? buffer,
    int bufferSize = 4096,
    int offset = 0,
  })  : _buf = buffer ?? Uint8List(bufferSize),
        _pos = offset,
        _flushStart = offset {
    if (offset < 0 || offset > _buf.length) {
      throw const SofabException(
          SofabError.invalidArgument, 'offset out of range');
    }
  }

  Uint8List _buf;
  int _pos;
  int _flushStart;
  final FlushCallback _flush;

  /// Reusable scratch for IEEE-754 payloads (little-endian).
  final ByteData _fscratch = ByteData(8);

  /// Encoder-side nesting depth guard (CORELIB_PLAN §4.9): must not open more
  /// than [maxDepth] sequences.
  int _depth = 0;

  // ---- buffer management -------------------------------------------------

  void _drain() {
    if (_pos > _flushStart) {
      _flush(Uint8List.sublistView(_buf, _flushStart, _pos));
    }
    _pos = 0;
    _flushStart = 0;
  }

  /// Installs a fresh output buffer mid-stream (typically from inside the flush
  /// callback) so encoding continues without interruption (CORELIB_PLAN §5.1).
  void installBuffer(Uint8List buffer, {int offset = 0}) {
    _buf = buffer;
    _pos = offset;
    _flushStart = offset;
  }

  void _writeByte(int b) {
    if (_pos >= _buf.length) _drain();
    if (_pos >= _buf.length) {
      throw const SofabException(
          SofabError.bufferFull, 'output buffer full and no room after flush');
    }
    _buf[_pos++] = b;
  }

  void _writeRaw(Uint8List src, int start, int end) {
    var i = start;
    while (i < end) {
      if (_pos >= _buf.length) _drain();
      if (_pos >= _buf.length) {
        throw const SofabException(SofabError.bufferFull,
            'output buffer full and no room after flush');
      }
      final room = _buf.length - _pos;
      final take = (end - i) < room ? (end - i) : room;
      _buf.setRange(_pos, _pos + take, src, i);
      _pos += take;
      i += take;
    }
  }

  /// Writes an unsigned LEB128 varint. [v] is treated as an unsigned 64-bit
  /// value via unsigned shifts, so the full u64 range round-trips.
  void _writeVarint(int v) {
    while (true) {
      final b = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        _writeByte(b);
        return;
      }
      _writeByte(b | 0x80);
    }
  }

  void _writeHeader(int id, int type) {
    if (id < 0 || id > idMax) {
      throw const SofabException(
          SofabError.invalidArgument, 'field id out of range 0..2^31-1');
    }
    _writeVarint((id << 3) | type);
  }

  // ---- scalars -----------------------------------------------------------

  /// Writes an unsigned integer (CORELIB_PLAN §4.4). [value] is the raw 64-bit
  /// bit pattern; pass negative Dart ints to express values ≥ 2^63.
  void writeUnsigned(int id, int value) {
    _writeHeader(id, WireType.unsigned);
    _writeVarint(value);
  }

  /// Writes a signed integer via zig-zag (CORELIB_PLAN §4.5).
  void writeSigned(int id, int value) {
    _writeHeader(id, WireType.signed);
    _writeVarint((value << 1) ^ (value >> 63));
  }

  /// Writes a boolean — an unsigned `0`/`1`; booleans have no wire type of their
  /// own (CORELIB_PLAN §4.4).
  void writeBool(int id, bool value) {
    _writeHeader(id, WireType.unsigned);
    _writeVarint(value ? 1 : 0);
  }

  /// Writes an IEEE-754 32-bit float (fixlen subtype fp32, CORELIB_PLAN §4.6).
  void writeFp32(int id, double value) {
    _writeHeader(id, WireType.fixlen);
    _writeVarint((4 << 3) | FixlenType.fp32);
    _fscratch.setFloat32(0, value, Endian.little);
    _writeRaw(_fscratch.buffer.asUint8List(0, 4), 0, 4);
  }

  /// Writes an IEEE-754 64-bit double (fixlen subtype fp64, CORELIB_PLAN §4.6).
  void writeFp64(int id, double value) {
    _writeHeader(id, WireType.fixlen);
    _writeVarint((8 << 3) | FixlenType.fp64);
    _fscratch.setFloat64(0, value, Endian.little);
    _writeRaw(_fscratch.buffer.asUint8List(0, 8), 0, 8);
  }

  /// Writes a UTF-8 string (fixlen subtype string, no null terminator). Rejects
  /// an unpaired surrogate with [SofabError.invalidArgument] — strict UTF-8,
  /// never lossy (CORELIB_PLAN §6.4).
  void writeString(int id, String value) {
    final bytes = encodeUtf8Strict(value);
    if (bytes == null) {
      throw const SofabException(SofabError.invalidArgument,
          'string is not valid UTF-8 (unpaired surrogate)');
    }
    _writeHeader(id, WireType.fixlen);
    _writeVarint((bytes.length << 3) | FixlenType.string);
    _writeRaw(bytes, 0, bytes.length);
  }

  /// Writes an opaque blob (fixlen subtype blob, CORELIB_PLAN §4.6).
  void writeBlob(int id, Uint8List value) {
    _writeHeader(id, WireType.fixlen);
    _writeVarint((value.length << 3) | FixlenType.blob);
    _writeRaw(value, 0, value.length);
  }

  // ---- arrays ------------------------------------------------------------

  /// Writes an array of unsigned integers (CORELIB_PLAN §4.7). The declared
  /// element width (u8..u64) is an API concern only; the wire carries varints.
  void writeUnsignedArray(int id, List<int> values) {
    _writeHeader(id, WireType.arrayUnsigned);
    _writeVarint(values.length);
    for (final v in values) {
      _writeVarint(v);
    }
  }

  /// Writes an array of signed integers via zig-zag (CORELIB_PLAN §4.7).
  void writeSignedArray(int id, List<int> values) {
    _writeHeader(id, WireType.arraySigned);
    _writeVarint(values.length);
    for (final v in values) {
      _writeVarint((v << 1) ^ (v >> 63));
    }
  }

  /// Writes an array of fp32 values (CORELIB_PLAN §4.8) — a single shared
  /// `fixlen_word`, then `count × 4` little-endian bytes. The word is present
  /// even when empty so an empty fp32 array stays distinct from an empty fp64
  /// array on the wire.
  void writeFp32Array(int id, List<double> values) {
    _writeHeader(id, WireType.arrayFixlen);
    _writeVarint(values.length);
    _writeVarint((4 << 3) | FixlenType.fp32);
    for (final v in values) {
      _fscratch.setFloat32(0, v, Endian.little);
      _writeRaw(_fscratch.buffer.asUint8List(0, 4), 0, 4);
    }
  }

  /// Writes an array of fp64 values (CORELIB_PLAN §4.8).
  void writeFp64Array(int id, List<double> values) {
    _writeHeader(id, WireType.arrayFixlen);
    _writeVarint(values.length);
    _writeVarint((8 << 3) | FixlenType.fp64);
    for (final v in values) {
      _fscratch.setFloat64(0, v, Endian.little);
      _writeRaw(_fscratch.buffer.asUint8List(0, 8), 0, 8);
    }
  }

  // ---- sequences ---------------------------------------------------------

  /// Opens a nested sequence — a fresh id scope (CORELIB_PLAN §4.9).
  void beginSequence(int id) {
    if (_depth >= maxDepth) {
      throw const SofabException(
          SofabError.invalidMessage, 'nesting exceeds MAX_DEPTH (255)');
    }
    _writeHeader(id, WireType.sequenceStart);
    _depth++;
  }

  /// Closes the current sequence — the single byte `0x07` (CORELIB_PLAN §4.9).
  void endSequence() {
    if (_depth <= 0) {
      throw const SofabException(
          SofabError.usageError, 'endSequence with no open sequence');
    }
    _writeByte(0x07);
    _depth--;
  }

  /// Drains any buffered bytes downstream (CORELIB_PLAN §5.1). Call once at the
  /// end of a message.
  void flush() => _drain();

  /// Resets the write position to [offset] so the encoder + its buffer can be
  /// reused for the next message without reallocating (hot-path friendly).
  void reset({int offset = 0}) {
    _pos = offset;
    _flushStart = offset;
    _depth = 0;
  }

  /// Bytes written into the current buffer but not yet flushed.
  int get pending => _pos - _flushStart;

  // ---- one-shot convenience ---------------------------------------------

  /// Encodes a whole message to a fresh [Uint8List] (the 90 %-case convenience,
  /// CORELIB_PLAN §6.1). Internally this is just the streaming path with a
  /// collecting sink, proving the one-shot helper is a thin wrapper.
  static Uint8List encodeToBytes(
    void Function(Encoder enc) build, {
    int bufferSize = 4096,
    int offset = 0,
  }) {
    final builder = BytesBuilder(copy: true);
    final enc = Encoder(builder.add, bufferSize: bufferSize, offset: offset);
    build(enc);
    enc.flush();
    return builder.toBytes();
  }
}
