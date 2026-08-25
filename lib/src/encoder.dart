import 'dart:typed_data';

import 'utf8.dart';
import 'wire.dart';

/// The continuation bit of all eight bytes of a 64-bit word.
const int _contBits = 0x8080808080808080;

/// Spreads the low 56 bits of [v] into eight 7-bit groups, one per byte of the
/// returned word (little-endian byte order = ascending varint groups).
///
/// This is the word-wise core of varint encoding: eight varint bytes are built
/// in a register and stored with a **single** 64-bit write instead of eight
/// bounds-checked byte writes. A byte store into a `Uint8List` costs ~15
/// instructions under Dart AOT (bounds check + safepoint-checked loop), while a
/// `ByteData.setUint64` costs ~20 for all eight — so this is worth ~2× on any
/// varint-heavy payload.
///
/// The spread itself is three log-steps rather than eight mask-shift-or terms:
/// split the 56 bits into two 28-bit halves four bytes apart, then each half
/// into 14s two bytes apart, then each of those into 7s one byte apart. 12
/// operations instead of 23.
@pragma('vm:prefer-inline')
int _spread56(int v) {
  var x = v & 0xFFFFFFFFFFFFFF;
  x = (x & 0xFFFFFFF) | ((x & 0xFFFFFFF0000000) << 4);
  x = (x & 0x00003FFF00003FFF) | ((x & 0x0FFFC0000FFFC000) << 2);
  return (x & 0x007F007F007F007F) | ((x & 0x3F803F803F803F80) << 1);
}

/// Byte length of the minimal unsigned-LEB128 encoding of [v], read as an
/// unsigned 64-bit value (a negative Dart int has bit 63 set → 10 bytes).
///
/// A binary search, not a linear chain: three comparisons for any length rather
/// than up to eight, which matters because large values (the ones that walk the
/// whole chain) are exactly the ones a varint-heavy payload is full of.
/// `bitLength` is not an option — it is a real call under Dart AOT, measured at
/// twice the cost of the entire surrounding loop.
@pragma('vm:prefer-inline')
int _varintLen(int v) {
  if (v < 0) return 10; // bit 63 set
  if (v < 0x10000000) {
    if (v < 0x4000) return v < 0x80 ? 1 : 2;
    return v < 0x200000 ? 3 : 4;
  }
  if (v < 0x100000000000000) {
    if (v < 0x40000000000) return v < 0x800000000 ? 5 : 6;
    return v < 0x2000000000000 ? 7 : 8;
  }
  return 9;
}

/// Writes the varint for [v] at [p] in [bd] and returns the new position.
///
/// **Caller must guarantee `p + 10 <= buffer.length`**: up to eight bytes are
/// stored unconditionally even for a shorter varint (the surplus lies beyond the
/// returned position and is overwritten by the next write or never flushed).
@pragma('vm:prefer-inline')
int _putVarint(Uint8List buf, ByteData bd, int p, int v) {
  if (v >= 0 && v < 0x80) {
    // Plain list store: `ByteData.setUint8` measured ~10 instructions dearer,
    // and single-byte varints are the most common thing the encoder writes.
    buf[p] = v;
    return p + 1;
  }
  final len = _varintLen(v);
  var w = _spread56(v);
  if (len <= 8) {
    // Continuation bit on every byte but the last.
    w |= _contBits & ((1 << ((len - 1) << 3)) - 1);
    bd.setUint64(p, w, Endian.little);
    return p + len;
  }
  bd.setUint64(p, w | _contBits, Endian.little);
  final hi = v >>> 56; // the remaining 8 value bits
  if (len == 9) {
    bd.setUint8(p + 8, hi);
    return p + 9;
  }
  bd.setUint16(p + 8, (hi & 0x7F) | 0x80 | ((hi >>> 7) << 8), Endian.little);
  return p + 10;
}

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
/// **Every buffer the encoder writes into is caller-supplied**, so `buffer` is
/// required: the corelib allocates no output buffer and never grows or replaces
/// one it was handed. There is one buffer-ownership model, not two — the layer
/// that knows how big a message can get is the one that allocates (CORELIB_PLAN
/// §5.1, "the generated-object layer allocates; the corelib does not"). The
/// one-shot [encodeToBytes] is that layer in miniature: it allocates once,
/// visibly, then drives this encoder like any other caller.
///
/// The hot path performs **no heap allocation**: scalars, headers, strings and
/// array elements are written straight into the caller-owned buffer, and the
/// only state the encoder keeps of its own — the held-back-sequence run and the
/// 8-byte float landing zone — is sized once, in the constructor
/// (CORELIB_PLAN §6.6).
///
/// Nested sequences are framed **lazily** ([beginSequenceLazy]): the header is
/// held back until the sequence receives content, so a sequence-typed field that
/// equals its declared default emits nothing at all (MESSAGE_SPEC §2). Close
/// with [endSequence] to let a contentless one vanish, or [endSequenceKeep] to
/// force the frame out — the wrapper-array **element** case, where presence
/// carries the array's length (MESSAGE_SPEC §5.1).
///
/// A buffer can also be handed over **without** a sink ([Encoder.overBuffer]):
/// then no flush can occur, so the buffer either holds the whole message —
/// [written] hands it back — or the write that does not fit throws
/// [SofabError.bufferFull]. That is the shape a caller sizing its buffer from a
/// generated `MAX_SIZE` wants, and it stays exact: a two-byte message encodes
/// into a two-byte buffer (CORELIB_PLAN §5.1).
class Encoder {
  /// Encodes into the caller-supplied [buffer], draining it through the flush
  /// sink whenever it fills (CORELIB_PLAN §5.1).
  ///
  /// [buffer] is required — a size to allocate from would be a second ownership
  /// model, and §5.1 has only one. [offset] leaves room at the front for a
  /// framing header. A sink-installed buffer must leave at least
  /// [minOutputBuffer] bytes after the offset.
  Encoder(
    FlushCallback this._flush, {
    required Uint8List buffer,
    int offset = 0,
  }) : _buf = buffer,
       _pos = offset,
       _flushStart = offset {
    _checkHandover(buffer.length, offset, streaming: true);
    _bufData = ByteData.sublistView(buffer);
    _fscratchBytes = _fscratch.buffer.asUint8List();
  }

  /// Encodes into a caller-supplied [buffer] with **no flush sink** — the first
  /// required capability of CORELIB_PLAN §5.1.
  ///
  /// No flush can occur, so nothing is ever handed downstream and nothing is
  /// ever dropped: the buffer holds the message, which [written] returns, or the
  /// write that runs out of room throws [SofabError.bufferFull]. [offset] leaves
  /// room at the front of [buffer] for a framing header, exactly as in the
  /// sink-installed form.
  ///
  /// No minimum applies to a sink-less buffer — a minimum is a *streaming*
  /// precondition, and here there is no streaming — so a message that encodes to
  /// two bytes fits a two-byte buffer. [flush] on such an encoder has nowhere to
  /// drain to and is a no-op that leaves the bytes in place.
  ///
  /// ```dart
  /// final buf = Uint8List(Person.maxSize);   // sized from the schema
  /// final enc = sofab.Encoder.overBuffer(buf);
  /// person.serialize(enc);
  /// enc.flush();
  /// socket.add(enc.written);                 // the whole message, zero-copy
  /// ```
  Encoder.overBuffer(Uint8List buffer, {int offset = 0})
    : _flush = null,
      _buf = buffer,
      _pos = offset,
      _flushStart = offset {
    _checkHandover(buffer.length, offset, streaming: false);
    _bufData = ByteData.sublistView(buffer);
    _fscratchBytes = _fscratch.buffer.asUint8List();
  }

  /// Validates a buffer handover (CORELIB_PLAN §5.1) — the constructor, the
  /// sink-less [Encoder.overBuffer] and every mid-stream [installBuffer] pass
  /// through here, so a buffer the encoder cannot use is refused **where it is
  /// handed over** rather than partway through a message.
  ///
  /// [streaming] is true exactly when a flush sink is present. Only then does
  /// [minOutputBuffer] bind: without a sink no flush can occur, no atomic unit
  /// can be split, and the buffer either holds the message or reports
  /// buffer-full — so a message that encodes to two bytes may be encoded into a
  /// two-byte buffer.
  static void _checkHandover(
    int buflen,
    int offset, {
    required bool streaming,
  }) {
    if (offset < 0 || offset > buflen) {
      throw const SofabException(
        SofabError.invalidArgument,
        'offset out of range',
      );
    }
    if (streaming && buflen - offset < minOutputBuffer) {
      throw const SofabException(
        SofabError.invalidArgument,
        'a buffer installed with a flush sink needs '
        'buflen - offset >= $minOutputBuffer (MIN_OUTPUT_BUFFER)',
      );
    }
  }

  Uint8List _buf;
  int _pos;
  int _flushStart;

  /// The flush sink, or `null` for a buffer installed without one — in which
  /// case [_drain] has nowhere to go and the buffer is all the room there is.
  final FlushCallback? _flush;

  /// Cached `ByteData` view of [_buf] so floats can be written straight into the
  /// output buffer (no scratch, no per-call view allocation). Refreshed whenever
  /// the buffer is swapped.
  ByteData _bufData = ByteData(0);

  /// Reusable scratch (+ its byte view) for the rare slow path where a float
  /// straddles the end of a tiny streaming buffer. Both are sized at
  /// construction (CORELIB_PLAN §6.6): bounded working state, never grown.
  final ByteData _fscratch = ByteData(8);
  late final Uint8List _fscratchBytes;

  /// Encoder-side nesting depth guard (CORELIB_PLAN §4.9): must not open more
  /// than [maxDepth] sequences.
  int _depth = 0;

  /// Ids of the innermost open sequences whose header has **not been written
  /// yet** (MESSAGE_SPEC §2 lazy framing, [beginSequenceLazy]). Always a
  /// contiguous suffix of the open sequences — writing any field commits the
  /// whole run at once — which is what lets [endSequence] simply pop the last
  /// entry.
  ///
  /// The run reaches the full [maxDepth], so the hold-back covers every legal
  /// nesting level and this port is canonical at every depth (CORELIB_PLAN
  /// §6.0.1, "How deep the hold-back reaches" — only a constrained profile may
  /// bound the run and frame eagerly beyond the bound, and this port takes no
  /// such bound). There is therefore no eager fallback, and one fewer way to
  /// break the contiguous-suffix invariant.
  ///
  /// **Sized at construction**, to that full extent: §6.0.1 makes the pending
  /// run fixed-size state and §6.6 requires such state to be "sized to its full
  /// extent when the codec is constructed" — "a pending run that doubles as
  /// nesting deepens allocates on a `write` path, and that is what this section
  /// forbids". One `Int32List(255)` per encoder, ~1 KiB, and nothing after it.
  ///
  /// These are **encoder state, not buffer content**: a flush can never split a
  /// pending run, which is why a tiny output buffer produces exactly the
  /// one-shot bytes.
  final Int32List _pendingSeq = Int32List(maxDepth);

  /// Number of valid entries in [_pendingSeq].
  int _nPendingSeq = 0;

  // ---- buffer management -------------------------------------------------

  /// Hands the bytes written so far to the sink and re-arms the cursor.
  ///
  /// The cursor is rewound **before** the callback runs, not after: 0 is the
  /// copying-sink default (a callback that returns without installing anything
  /// has copied the bytes, so the active buffer stays active and is refilled
  /// from its start), and rewinding first lets an [installBuffer] call made
  /// from inside the callback have the last word. That is exactly the
  /// CORELIB_PLAN §5.1 contract — *the start offset belongs to the
  /// installation, not to the buffer* — and it is what makes the taking-sink
  /// shape work: a sink that hands its buffer on installs a replacement with
  /// its own offset and so re-arms framing-header room in **every** flushed
  /// unit, where resetting afterwards would silently drop that offset and
  /// overwrite the room the caller reserved.
  ///
  /// **Without a sink there is nowhere to drain to** (CORELIB_PLAN §5.1): the
  /// bytes stay exactly where they are and the cursor is *not* rewound, so the
  /// caller that runs out of room gets [SofabError.bufferFull] from the write
  /// itself instead of watching the overflow disappear. Rewinding here would
  /// return partial output as if it were complete, which §5.1 forbids.
  void _drain() {
    final flush = _flush;
    if (flush == null) return;
    final start = _flushStart, end = _pos;
    _pos = 0;
    _flushStart = 0;
    if (end > start) {
      flush(Uint8List.sublistView(_buf, start, end));
    }
  }

  /// Installs a fresh output buffer mid-stream (typically from inside the flush
  /// callback) so encoding continues without interruption (CORELIB_PLAN §5.1).
  ///
  /// [offset] belongs to *this* installation: writing resumes at that byte of
  /// [buffer], leaving room at the front for a framing header. The offset is
  /// consumed by the installation, so a later flush that the callback returns
  /// from without installing anything resumes at 0. Passing the **same** buffer
  /// back is a new installation like any other — that is how a sink re-arms its
  /// header room once per flushed packet.
  ///
  /// On an encoder **with** a flush sink the installation must leave at least
  /// [minOutputBuffer] bytes of room (`buffer.length - offset`); one byte less
  /// is rejected right here with [SofabError.invalidArgument] — the same
  /// mechanism as an out-of-range [offset] — and the encoder keeps writing into
  /// the buffer it already had (CORELIB_PLAN §5.1). A buffer installed
  /// **without** a sink is subject to no minimum.
  void installBuffer(Uint8List buffer, {int offset = 0}) {
    _checkHandover(buffer.length, offset, streaming: _flush != null);
    _buf = buffer;
    _bufData = ByteData.sublistView(buffer);
    _pos = offset;
    _flushStart = offset;
  }

  void _writeByte(int b) {
    if (_pos >= _buf.length) _drain();
    if (_pos >= _buf.length) {
      throw const SofabException(
        SofabError.bufferFull,
        'output buffer full and no room after flush',
      );
    }
    _buf[_pos++] = b;
  }

  void _writeRaw(Uint8List src, int start, int end) {
    var i = start;
    while (i < end) {
      if (_pos >= _buf.length) _drain();
      if (_pos >= _buf.length) {
        throw const SofabException(
          SofabError.bufferFull,
          'output buffer full and no room after flush',
        );
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
  ///
  /// Fast path: when the current buffer has room for a maximal (10-byte) varint,
  /// build the whole varint in a register and store it with one 64-bit write
  /// ([_putVarint]) — no per-byte bounds check, no per-byte flush-capacity
  /// branch. Tiny streaming buffers fall back to the per-byte [_writeByte] path.
  void _writeVarint(int v) {
    final p = _pos;
    // Single-byte varint (every small id/count/value) — a plain `Uint8List`
    // store, which is cheaper than routing through the `ByteData` view.
    if (v >= 0 && v < 0x80) {
      if (p < _buf.length) {
        _buf[p] = v;
        _pos = p + 1;
        return;
      }
    } else if (p + 10 <= _buf.length) {
      _pos = _putVarint(_buf, _bufData, p, v);
      return;
    }
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

  /// Writes a field header — the `(id << 3) | wire_type` tag as a varint.
  ///
  /// This is the **single choke point every field write passes through** (every
  /// `write*` method below calls it before its first payload byte), so it is
  /// also where a held-back sequence run is committed: the field about to be
  /// written is content, which proves every enclosing sequence differs from its
  /// default and must be framed after all (MESSAGE_SPEC §2).
  ///
  /// Sequence start/end are not content and never trigger the commit —
  /// [beginSequenceLazy] does not route through here at all, and
  /// [endSequenceKeep] commits explicitly.
  ///
  /// Kept deliberately small — the commit itself lives in a separate
  /// never-inlined method — so the AOT compiler keeps folding this into each
  /// `write*` caller. Inlining it is worth ~30 instructions per field.
  @pragma('vm:prefer-inline')
  void _writeHeader(int id, int type) {
    if (id < 0 || id > idMax) {
      throw const SofabException(
        SofabError.invalidArgument,
        'field id out of range 0..2^31-1',
      );
    }
    if (_nPendingSeq != 0) _commitPendingSequences();
    _writeVarint((id << 3) | type);
  }

  /// Emits the held-back sequence headers, **outermost first**, so the run
  /// reaches the wire in exactly the order an eager encoder would have written
  /// it. Runs at most once per non-default sequence run, never per field.
  ///
  /// The cold half of the choke point (Rust marks it `#[cold] #[inline(never)]`
  /// for the same reason): keeping it out of line is what lets [_writeHeader]
  /// stay inlined into every writer.
  @pragma('vm:never-inline')
  void _commitPendingSequences() {
    final ids = _pendingSeq;
    final n = _nPendingSeq;
    _nPendingSeq = 0;
    for (var i = 0; i < n; i++) {
      _writeVarint((ids[i] << 3) | WireType.sequenceStart);
    }
  }

  /// Writes a field header immediately followed by one varint payload — the
  /// shape of every integer scalar.
  ///
  /// Both varints are emitted under a **single** capacity check (a header plus a
  /// value is at most 20 bytes), which halves the buffer-length loads and bounds
  /// tests per field compared with two independent [_writeVarint] calls.
  @pragma('vm:prefer-inline')
  void _writeHeaderAndVarint(int id, int type, int value) {
    if (id < 0 || id > idMax) {
      throw const SofabException(
        SofabError.invalidArgument,
        'field id out of range 0..2^31-1',
      );
    }
    // Must precede reading `_pos`: committing writes bytes of its own.
    if (_nPendingSeq != 0) _commitPendingSequences();
    final buf = _buf;
    final p = _pos;
    if (p + 20 <= buf.length) {
      final bd = _bufData;
      _pos = _putVarint(
        buf,
        bd,
        _putVarint(buf, bd, p, (id << 3) | type),
        value,
      );
      return;
    }
    _writeVarint((id << 3) | type);
    _writeVarint(value);
  }

  // ---- scalars -----------------------------------------------------------

  /// Writes an unsigned integer (CORELIB_PLAN §4.4). [value] is the raw 64-bit
  /// bit pattern; pass negative Dart ints to express values ≥ 2^63.
  void writeUnsigned(int id, int value) =>
      _writeHeaderAndVarint(id, WireType.unsigned, value);

  /// Writes a signed integer via zig-zag (CORELIB_PLAN §4.5).
  void writeSigned(int id, int value) =>
      _writeHeaderAndVarint(id, WireType.signed, (value << 1) ^ (value >> 63));

  /// Writes a boolean — an unsigned `0`/`1`; booleans have no wire type of their
  /// own (CORELIB_PLAN §4.4).
  void writeBool(int id, bool value) =>
      _writeHeaderAndVarint(id, WireType.unsigned, value ? 1 : 0);

  /// Writes 4 float bytes little-endian straight into the buffer when there is
  /// room, else via the scratch slow path (tiny streaming buffer).
  void _putFloat32(double v) {
    if (_pos + 4 <= _buf.length) {
      _bufData.setFloat32(_pos, v, Endian.little);
      _pos += 4;
    } else {
      _fscratch.setFloat32(0, v, Endian.little);
      _writeRaw(_fscratchBytes, 0, 4);
    }
  }

  /// Writes 4 raw little-endian bytes of a 32-bit bit pattern with no float
  /// interpretation — the bit-exact fp32 primitive (§4.6: never normalize).
  void _putUint32(int bits) {
    if (_pos + 4 <= _buf.length) {
      _bufData.setUint32(_pos, bits, Endian.little);
      _pos += 4;
    } else {
      _fscratch.setUint32(0, bits, Endian.little);
      _writeRaw(_fscratchBytes, 0, 4);
    }
  }

  void _putFloat64(double v) {
    if (_pos + 8 <= _buf.length) {
      _bufData.setFloat64(_pos, v, Endian.little);
      _pos += 8;
    } else {
      _fscratch.setFloat64(0, v, Endian.little);
      _writeRaw(_fscratchBytes, 0, 8);
    }
  }

  /// Writes an IEEE-754 32-bit float (fixlen subtype fp32, CORELIB_PLAN §4.6).
  void writeFp32(int id, double value) {
    _writeHeaderAndVarint(id, WireType.fixlen, (4 << 3) | FixlenType.fp32);
    _putFloat32(value);
  }

  /// Writes an fp32 field from its raw 32-bit IEEE-754 bit pattern (the low 32
  /// bits of [bits]), bypassing the float widening that [writeFp32] performs.
  ///
  /// Use this when a value must survive **bit-for-bit** — notably a signaling
  /// NaN, whose "is-quiet" bit a Dart `double` (64-bit) would set on the way in.
  /// The corelib never inspects or normalizes a float (CORELIB_PLAN §4.6), so
  /// the four bytes are emitted exactly as given.
  void writeFp32Bits(int id, int bits) {
    _writeHeaderAndVarint(id, WireType.fixlen, (4 << 3) | FixlenType.fp32);
    _putUint32(bits & 0xFFFFFFFF);
  }

  /// Writes an IEEE-754 64-bit double (fixlen subtype fp64, CORELIB_PLAN §4.6).
  void writeFp64(int id, double value) {
    _writeHeaderAndVarint(id, WireType.fixlen, (8 << 3) | FixlenType.fp64);
    _putFloat64(value);
  }

  /// Writes a UTF-8 string (fixlen subtype string, no null terminator). Rejects
  /// an unpaired surrogate with [SofabError.invalidArgument] — strict UTF-8,
  /// never lossy (CORELIB_PLAN §6.4).
  void writeString(int id, String value) {
    if (_writeStringAscii(id, value)) return;
    _writeStringSlow(id, value);
  }

  /// Writes [value] as a `string` field in **one pass** over its code units, or
  /// returns false having written nothing.
  ///
  /// A pure-ASCII string (each code unit < 0x80 → one UTF-8 byte, and trivially
  /// valid UTF-8) is the common case — field names, ids, tags, keys — and its
  /// wire length is known before the string is looked at: it is the code-unit
  /// count. So the header and the `fixlen_word` can go out first and the code
  /// units be tested and stored in the same pass, instead of one pass to prove
  /// the string ASCII and a second to copy it. `codeUnitAt` is a real call under
  /// Dart AOT (`String` is not a single concrete class), and it was being made
  /// twice per character.
  ///
  /// The speculation is free because it is only entered with room for
  /// everything it could write — any held-back sequence headers (at most five
  /// bytes each), this header, a maximal `fixlen_word` and every code unit. No
  /// flush can occur inside that, so a non-ASCII code unit part-way in rewinds
  /// the cursor *and* the pending-sequence run and leaves no trace at all: the
  /// bytes, and the state a failed write leaves behind, are exactly what the
  /// two-pass [_writeStringSlow] would have produced.
  bool _writeStringAscii(int id, String value) {
    if (id < 0 || id > idMax) return false; // let the slow path raise it
    final n = value.length;
    final buf = _buf;
    final start = _pos;
    final pending = _nPendingSeq;
    if (start + pending * 5 + 20 + n > buf.length) return false;
    if (pending != 0) _commitPendingSequences();
    final bd = _bufData;
    var p = _putVarint(buf, bd, _pos, (id << 3) | WireType.fixlen);
    p = _putVarint(buf, bd, p, (n << 3) | FixlenType.string);
    for (var i = 0; i < n; i++) {
      final c = value.codeUnitAt(i);
      if (c >= 0x80) {
        _pos = start; // not ASCII after all: undo, down to the held-back run
        _nPendingSeq = pending;
        return false;
      }
      buf[p++] = c;
    }
    _pos = p;
    return true;
  }

  /// The general `string` path: a buffer too small to speculate in (a streaming
  /// encoder draining through a tiny buffer), and every string that is not pure
  /// ASCII.
  void _writeStringSlow(int id, String value) {
    final n = value.length;
    var ascii = true;
    for (var i = 0; i < n; i++) {
      if (value.codeUnitAt(i) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) {
      _writeHeaderAndVarint(id, WireType.fixlen, (n << 3) | FixlenType.string);
      for (var i = 0; i < n; i++) {
        _writeByte(value.codeUnitAt(i));
      }
      return;
    }
    // Non-ASCII: strict transcode (allocates), rejecting unpaired surrogates.
    final bytes = encodeUtf8Strict(value);
    if (bytes == null) {
      throw const SofabException(
        SofabError.invalidArgument,
        'string is not valid UTF-8 (unpaired surrogate)',
      );
    }
    _writeHeaderAndVarint(
      id,
      WireType.fixlen,
      (bytes.length << 3) | FixlenType.string,
    );
    _writeRaw(bytes, 0, bytes.length);
  }

  /// Writes an opaque blob (fixlen subtype blob, CORELIB_PLAN §4.6).
  void writeBlob(int id, Uint8List value) {
    _writeHeaderAndVarint(
      id,
      WireType.fixlen,
      (value.length << 3) | FixlenType.blob,
    );
    _writeRaw(value, 0, value.length);
  }

  // ---- arrays ------------------------------------------------------------

  /// Writes an array of unsigned integers (CORELIB_PLAN §4.7). The declared
  /// element width (u8..u64) is an API concern only; the wire carries varints.
  void writeUnsignedArray(int id, List<int> values) {
    _writeHeader(id, WireType.arrayUnsigned);
    final n = values.length;
    _writeVarint(n);
    var p = _pos;
    // Bulk fast path: one capacity check for the whole array, then a word-wise
    // varint per element ([_putVarint]) with the position kept in a local — no
    // per-element field reload and no per-byte bounds check.
    //
    // The `is Int64List` arm exists because `List<int>` is an *interface* call
    // per element; promoting to the concrete type lets AOT inline the load.
    final buf = _buf;
    if (p + n * 10 <= buf.length) {
      final bd = _bufData;
      if (values is Int64List) {
        for (var k = 0; k < n; k++) {
          p = _putVarint(buf, bd, p, values[k]);
        }
      } else {
        for (var k = 0; k < n; k++) {
          p = _putVarint(buf, bd, p, values[k]);
        }
      }
      _pos = p;
    } else {
      for (var k = 0; k < n; k++) {
        _writeVarint(values[k]);
      }
    }
  }

  /// Writes an array of signed integers via zig-zag (CORELIB_PLAN §4.7).
  void writeSignedArray(int id, List<int> values) {
    _writeHeader(id, WireType.arraySigned);
    final n = values.length;
    _writeVarint(n);
    var p = _pos;
    final buf = _buf;
    if (p + n * 10 <= buf.length) {
      final bd = _bufData;
      if (values is Int64List) {
        for (var k = 0; k < n; k++) {
          final s = values[k];
          p = _putVarint(buf, bd, p, (s << 1) ^ (s >> 63)); // zig-zag
        }
      } else {
        for (var k = 0; k < n; k++) {
          final s = values[k];
          p = _putVarint(buf, bd, p, (s << 1) ^ (s >> 63)); // zig-zag
        }
      }
      _pos = p;
    } else {
      for (var k = 0; k < n; k++) {
        final s = values[k];
        _writeVarint((s << 1) ^ (s >> 63));
      }
    }
  }

  /// Writes an array of fp32 values (CORELIB_PLAN §4.8) — a single shared
  /// `fixlen_word`, then `count × 4` little-endian bytes. The word is present
  /// even when empty so an empty fp32 array stays distinct from an empty fp64
  /// array on the wire.
  void writeFp32Array(int id, List<double> values) {
    _writeHeader(id, WireType.arrayFixlen);
    final n = values.length;
    _writeVarint(n);
    _writeVarint((4 << 3) | FixlenType.fp32);
    // Bit-exact fast path: a Float32List already holds the raw 32-bit elements,
    // so on a little-endian host its bytes are exactly the wire bytes — copy
    // them straight out with no widening to a double, so a signaling NaN
    // survives (§4.6). This is also faster than a per-element float write.
    if (values is Float32List && Endian.host == Endian.little) {
      _writeRaw(Uint8List.sublistView(values), 0, n * 4);
      return;
    }
    var p = _pos;
    if (p + n * 4 <= _buf.length) {
      final bd = _bufData;
      for (var k = 0; k < n; k++) {
        bd.setFloat32(p, values[k], Endian.little);
        p += 4;
      }
      _pos = p;
    } else {
      for (var k = 0; k < n; k++) {
        _putFloat32(values[k]);
      }
    }
  }

  /// Writes an array of fp64 values (CORELIB_PLAN §4.8).
  void writeFp64Array(int id, List<double> values) {
    _writeHeader(id, WireType.arrayFixlen);
    final n = values.length;
    _writeVarint(n);
    _writeVarint((8 << 3) | FixlenType.fp64);
    var p = _pos;
    if (p + n * 8 <= _buf.length) {
      final bd = _bufData;
      for (var k = 0; k < n; k++) {
        bd.setFloat64(p, values[k], Endian.little);
        p += 8;
      }
      _pos = p;
    } else {
      for (var k = 0; k < n; k++) {
        _putFloat64(values[k]);
      }
    }
  }

  // ---- sequences ---------------------------------------------------------

  /// Opens a nested sequence — a fresh id scope (CORELIB_PLAN §4.9) — whose
  /// header is **held back** until the sequence turns out to have content.
  ///
  /// MESSAGE_SPEC §2 omits a sequence-typed field whose value equals its
  /// declared default, and "not one child was written" is exactly that
  /// condition — evaluated per child field, recursively, for free, because the
  /// message layer already omits every child equal to its default. A sequence
  /// closed with nothing in it therefore emits **nothing** instead of a two-byte
  /// empty frame, and an all-default message becomes the empty byte string.
  ///
  /// The predicate is never a byte image of the object, so struct padding and
  /// in-memory layout cannot influence it, and a non-zero nested default is
  /// handled by the caller's ordinary per-field test.
  ///
  /// This is the **only** way to open a sequence. How it closes decides whether
  /// a contentless one survives: [endSequence] drops it, [endSequenceKeep]
  /// forces the frame out.
  ///
  /// There is **no depth window**: the pending run grows on demand and holds
  /// back to the full [maxDepth], so a contentless nest is dropped at every
  /// legal depth and the output is canonical everywhere (CORELIB_PLAN §6).
  /// Nesting itself is still bounded — opening more than [maxDepth] sequences
  /// throws [SofabError.invalidMessage].
  void beginSequenceLazy(int id) {
    if (_depth >= maxDepth) {
      throw const SofabException(
        SofabError.invalidMessage,
        'nesting exceeds MAX_DEPTH (255)',
      );
    }
    if (id < 0 || id > idMax) {
      throw const SofabException(
        SofabError.invalidArgument,
        'field id out of range 0..2^31-1',
      );
    }
    // The run holds [maxDepth] entries and the depth check above has already
    // refused the one that would overflow it, so there is nothing to grow.
    _pendingSeq[_nPendingSeq++] = id;
    _depth++;
  }

  /// Closes the current sequence, letting it **vanish** if it received no
  /// content; otherwise the single byte `0x07` (CORELIB_PLAN §4.9).
  ///
  /// Use it wherever absence encodes the same value as an empty frame: a
  /// `struct`/`union` field, and an array field whose declared `default` is the
  /// empty collection (MESSAGE_SPEC §2). Where the frame must be visible, close
  /// with [endSequenceKeep] instead.
  ///
  /// An end with no matching begin is not rejected: the encoder writes what it
  /// is told, and the resulting bytes are then malformed, which is the decoder's
  /// verdict to make. Every other port behaves this way; the depth counter stops
  /// at zero so the `MAX_DEPTH` check on begin cannot be fooled by an underflow.
  void endSequence() {
    if (_nPendingSeq != 0) {
      // The innermost open sequence is the last held-back one and it got no
      // content: drop it — header and end marker both.
      _nPendingSeq--;
      if (_depth > 0) _depth--;
      return;
    }
    _writeByte(0x07);
    if (_depth > 0) _depth--;
  }

  /// Closes the current sequence, **keeping** its frame even when it received no
  /// content.
  ///
  /// Behaves like a write: it first emits any held-back headers — this frame's
  /// and every enclosing one's — and then the end marker, so a contentless
  /// sequence still reaches the wire as `begin` + `end`.
  ///
  /// Required wherever the frame carries information beyond its contents:
  /// - a **wrapper-array element** (`struct`/`union`/nested row): element
  ///   presence is what carries a dynamic array's length — *highest present id
  ///   + 1* (MESSAGE_SPEC §5.1) — so dropping an all-default element would
  ///   change the decoded **length**, not just the bytes;
  /// - an array field already known to **differ from a non-empty declared
  ///   `default`**: absence would reconstruct that default, so the empty frame
  ///   is the only encoding of "explicitly empty" (MESSAGE_SPEC §2, §3).
  ///
  /// The two failure directions are not symmetric, which is why this is the safe
  /// choice when in doubt: using it where [endSequence] would do costs one
  /// non-canonical empty frame that every decoder normalizes away, while the
  /// reverse silently changes an array's length.
  void endSequenceKeep() {
    if (_nPendingSeq != 0) _commitPendingSequences();
    _writeByte(0x07);
    if (_depth > 0) _depth--;
  }

  /// Drains any buffered bytes downstream (CORELIB_PLAN §5.1). Call once at the
  /// end of a message.
  ///
  /// On a sink-less encoder ([Encoder.overBuffer]) there is nowhere to drain to:
  /// the message is already in the caller's buffer, where [written] returns it,
  /// and this is a no-op that leaves it there.
  void flush() => _drain();

  /// Resets the write position to [offset] so the encoder + its buffer can be
  /// reused for the next message without reallocating (hot-path friendly).
  void reset({int offset = 0}) {
    _pos = offset;
    _flushStart = offset;
    _depth = 0;
    _nPendingSeq = 0;
  }

  /// Bytes written into the current buffer but not yet flushed.
  int get pending => _pos - _flushStart;

  /// The bytes written into the active buffer since it was installed — the
  /// whole message for a sink-less encoder ([Encoder.overBuffer]) that had room
  /// for it, and whatever has not been flushed yet otherwise.
  ///
  /// A **view** over the caller's buffer (no copy), valid until the next write
  /// or buffer installation. It starts at the installation's `offset`, so the
  /// framing-header room a caller reserved is not part of it.
  Uint8List get written => Uint8List.sublistView(_buf, _flushStart, _pos);

  // ---- one-shot convenience ---------------------------------------------

  /// Encodes a whole message to a fresh [Uint8List] (the 90 %-case convenience,
  /// CORELIB_PLAN §6.1). Internally this is just the streaming path with a
  /// collecting sink, proving the one-shot helper is a thin wrapper.
  ///
  /// This is the **one** place the package allocates output storage, and it does
  /// so as a *caller* would: it allocates a scratch buffer of [bufferSize] bytes
  /// here, explicitly, and hands it to the encoder like any other caller
  /// (CORELIB_PLAN §5.1, "the generated-object layer allocates; the corelib does
  /// not" — the unbounded shape, a scratch buffer plus an appending sink). The
  /// encoder itself allocates nothing: a caller that owns its storage uses the
  /// streaming constructor or [Encoder.overBuffer] and never comes through here.
  static Uint8List encodeToBytes(
    void Function(Encoder enc) build, {
    int bufferSize = 4096,
    int offset = 0,
  }) {
    final builder = BytesBuilder(copy: true);
    final enc = Encoder(
      builder.add,
      buffer: Uint8List(bufferSize),
      offset: offset,
    );
    build(enc);
    enc.flush();
    return builder.toBytes();
  }
}
