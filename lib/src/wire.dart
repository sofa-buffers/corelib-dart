// Wire-format constants and shared types (CORELIB_PLAN §4, §6.2, §6.3).
//
// Everything on the wire is little-endian; integers are LEB128-style varints.
// These values are normative and identical across every SofaBuffers port.

/// The integer API version (CORELIB_PLAN §6.2).
const int apiVersion = 1;

/// Field-ID / length / count ceiling: 2^31 − 1 (CORELIB_PLAN §6.2).
const int idMax = 2147483647;
const int fixlenMax = 2147483647;
const int arrayMax = 2147483647;

/// Maximum nested-sequence depth (CORELIB_PLAN §4.9, §6.2).
const int maxDepth = 255;

/// The eight wire types — the low 3 bits of a field header (CORELIB_PLAN §4.3).
class WireType {
  WireType._();
  static const int unsigned = 0; // 0b000 unsigned varint
  static const int signed = 1; // 0b001 zig-zag varint
  static const int fixlen = 2; // 0b010 length-prefixed value
  static const int arrayUnsigned = 3; // 0b011 array of unsigned
  static const int arraySigned = 4; // 0b100 array of signed
  static const int arrayFixlen = 5; // 0b101 array of fixlen (fp32/fp64)
  static const int sequenceStart = 6; // 0b110 open a fresh id scope
  static const int sequenceEnd = 7; // 0b111 close current scope
}

/// The fixlen subtype — the low 3 bits of a `fixlen_word` (CORELIB_PLAN §4.6).
class FixlenType {
  FixlenType._();
  static const int fp32 = 0; // IEEE-754 32-bit, exactly 4 bytes
  static const int fp64 = 1; // IEEE-754 64-bit, exactly 8 bytes
  static const int string = 2; // UTF-8, no null terminator
  static const int blob = 3; // opaque bytes
  // 4..7 are reserved and MUST be rejected as INVALID.
}

/// The three-valued decode outcome (CORELIB_PLAN §5.2), plus [limitExceeded]
/// which surfaces a receiver-side policy limit distinctly (CORELIB_PLAN §6.2.1,
/// §6.3): the four-outcome option the spec explicitly permits.
enum DecodeStatus {
  /// Consumed bytes end exactly at a field boundary; a valid message may end
  /// here. More valid fields may still extend it.
  complete,

  /// Bytes end inside a field (unterminated varint, short fixlen payload, or an
  /// unclosed sequence). NOT an error — feed more bytes to continue.
  incomplete,

  /// Bytes are malformed regardless of what follows. Terminal.
  invalid,

  /// A configured receiver-side technical limit was exceeded on a
  /// schema-unbounded field. The bytes are well-formed; this is a terminal
  /// policy rejection, never folded into [invalid].
  limitExceeded,
}

/// Result / error codes for fallible operations (CORELIB_PLAN §6.3). In Dart —
/// an exception-idiomatic language — encoder failures throw [SofabException]
/// carrying one of these; the decoder reports [DecodeStatus] instead.
enum SofabError {
  ok,
  usageError,
  bufferFull,
  invalidArgument,
  invalidMessage,
  limitExceeded,
}

/// Thrown by encoder operations and by convenience decoders on failure.
class SofabException implements Exception {
  const SofabException(this.code, this.message);
  final SofabError code;
  final String message;

  @override
  String toString() => 'SofabException(${code.name}): $message';
}
