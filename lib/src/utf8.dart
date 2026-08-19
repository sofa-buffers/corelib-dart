import 'dart:convert' show utf8;
import 'dart:typed_data';

// Strict UTF-8 primitives (CORELIB_PLAN §6.4). Dart's `String` is a Unicode
// (UTF-16) type, so per §6.4 this port is *always strict*: it never substitutes
// U+FFFD or drops bytes. `SOFAB_STRICT_UTF8` is therefore a documented no-op /
// always-ON for Dart, and these primitives are the real validators — not
// byte-range shortcuts.

/// Validates that [bytes] (optionally the sub-range `[start, end)`) is
/// well-formed UTF-8 per RFC 3629. Rejects overlong encodings (including the
/// `C0 80` "Modified UTF-8" NUL), surrogate code points U+D800–U+DFFF, and code
/// points above U+10FFFF. A bare/embedded `U+0000` (single `0x00`) is valid.
///
/// This is the `utf8_valid` primitive of CORELIB_PLAN §6.4.
bool utf8Valid(Uint8List bytes, [int start = 0, int? end]) {
  final n = end ?? bytes.length;
  var i = start;
  while (i < n) {
    final c = bytes[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    if (c < 0xC2) {
      return false; // 0x80–0xBF stray continuation, or C0/C1 overlong lead
    }
    if (c <= 0xDF) {
      // 2-byte: C2–DF 80–BF
      if (i + 1 >= n) return false;
      final b1 = bytes[i + 1];
      if (b1 < 0x80 || b1 > 0xBF) return false;
      i += 2;
    } else if (c <= 0xEF) {
      // 3-byte: E0 A0–BF | E1–EC 80–BF | ED 80–9F | EE–EF 80–BF, then 80–BF
      if (i + 2 >= n) return false;
      final b1 = bytes[i + 1];
      final b2 = bytes[i + 2];
      int lo = 0x80, hi = 0xBF;
      if (c == 0xE0) {
        lo = 0xA0; // reject overlong
      } else if (c == 0xED) {
        hi = 0x9F; // reject surrogates D800–DFFF
      }
      if (b1 < lo || b1 > hi) return false;
      if (b2 < 0x80 || b2 > 0xBF) return false;
      i += 3;
    } else if (c <= 0xF4) {
      // 4-byte: F0 90–BF | F1–F3 80–BF | F4 80–8F, then two 80–BF
      if (i + 3 >= n) return false;
      final b1 = bytes[i + 1];
      final b2 = bytes[i + 2];
      final b3 = bytes[i + 3];
      int lo = 0x80, hi = 0xBF;
      if (c == 0xF0) {
        lo = 0x90; // reject overlong
      } else if (c == 0xF4) {
        hi = 0x8F; // reject > U+10FFFF
      }
      if (b1 < lo || b1 > hi) return false;
      if (b2 < 0x80 || b2 > 0xBF) return false;
      if (b3 < 0x80 || b3 > 0xBF) return false;
      i += 4;
    } else {
      return false; // F5–FF
    }
  }
  return true;
}

/// Strictly encodes a Dart [String] to UTF-8 bytes, returning `null` if the
/// string contains an **unpaired surrogate** (the only way a Dart `String` can
/// fail to be valid Unicode). Never emits U+FFFD — a strict/fatal encoder as
/// CORELIB_PLAN §6.4 requires (Dart's `utf8.encode`/`TextEncoder` are lossy on
/// unpaired surrogates and must not be used here).
Uint8List? encodeUtf8Strict(String s) {
  final units = s.codeUnits;
  final n = units.length;
  // Worst case 3 bytes per BMP code unit; surrogate pairs collapse 2 units → 4
  // bytes, so 3*n is always sufficient.
  final out = Uint8List(n * 3);
  var o = 0;
  var i = 0;
  while (i < n) {
    final c = units[i++];
    if (c < 0x80) {
      out[o++] = c;
    } else if (c < 0x800) {
      out[o++] = 0xC0 | (c >> 6);
      out[o++] = 0x80 | (c & 0x3F);
    } else if (c >= 0xD800 && c <= 0xDBFF) {
      // High surrogate: must be followed by a low surrogate.
      if (i >= n) return null;
      final c2 = units[i];
      if (c2 < 0xDC00 || c2 > 0xDFFF) return null;
      i++;
      final cp = 0x10000 + (((c - 0xD800) << 10) | (c2 - 0xDC00));
      out[o++] = 0xF0 | (cp >> 18);
      out[o++] = 0x80 | ((cp >> 12) & 0x3F);
      out[o++] = 0x80 | ((cp >> 6) & 0x3F);
      out[o++] = 0x80 | (cp & 0x3F);
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return null; // lone low surrogate
    } else {
      out[o++] = 0xE0 | (c >> 12);
      out[o++] = 0x80 | ((c >> 6) & 0x3F);
      out[o++] = 0x80 | (c & 0x3F);
    }
  }
  return Uint8List.sublistView(out, 0, o);
}

/// Strictly decodes UTF-8 [bytes] to a Dart [String], returning `null` if they
/// are not well-formed UTF-8 per RFC 3629 — the decode-side twin of
/// [encodeUtf8Strict], and never lossy: no U+FFFD substitution, no dropped
/// byte (CORELIB_PLAN §6.4).
///
/// This is the materialization step a **schema-bound (generated) consumer**
/// runs inside a matched destination arm of `MessageVisitor.onStringBytes`, and
/// it is the same code the default `onStringBytes` runs — validate once, then
/// build the string — rather than a separate [utf8Valid] scan of the whole
/// payload followed by an independent transcode of it from byte zero.
///
/// The ASCII fast path is why: a byte below `0x80` is a complete, trivially
/// valid UTF-8 sequence, so one scan settles validity *and* the transcode for
/// an all-ASCII payload — `String.fromCharCodes` builds the one-byte string
/// directly, touching neither the general validator nor the UTF-8 decoder.
/// Field names, ids, tags and most identifiers are exactly that. A payload that
/// does turn multi-byte is validated only from its **first non-ASCII byte**,
/// which is a legal resync point precisely because every byte before it stands
/// alone.
String? decodeUtf8Strict(Uint8List bytes) {
  final n = bytes.length;
  var i = 0;
  while (i < n && bytes[i] < 0x80) {
    i++;
  }
  if (i == n) return String.fromCharCodes(bytes);
  if (!utf8Valid(bytes, i)) return null;
  return utf8.decode(bytes);
}

/// The exact number of UTF-8 bytes [s] encodes to, without allocating the
/// transcode buffer [encodeUtf8Strict] would.
///
/// This is what sizes a `fixlen_word` (and any buffer reservation) ahead of a
/// string payload: the wire `length` of a `string` field is its UTF-8 byte
/// length, not its Dart `String` length, and the two differ for anything above
/// U+007F.
///
/// The walk is over code **units**, not runes: a surrogate pair is recognized
/// and counted as the 4 bytes its code point encodes to, and no `RuneIterator`
/// is allocated to find that out. An *unpaired* surrogate — the one thing a
/// Dart `String` can hold that is not encodable at all, and for which
/// [encodeUtf8Strict] returns `null` — is counted as 3 bytes here rather than
/// reported: this answers "how large", and whether the string can be encoded is
/// the encoder's answer to give.
int utf8Length(String s) {
  final units = s.codeUnits;
  final n = units.length;
  var len = 0;
  var i = 0;
  while (i < n) {
    final c = units[i++];
    if (c < 0x80) {
      len += 1;
    } else if (c < 0x800) {
      len += 2;
    } else if (c >= 0xD800 && c <= 0xDBFF && i < n) {
      final c2 = units[i];
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        i++;
        len += 4; // surrogate pair: one code point above U+FFFF
      } else {
        len += 3; // unpaired high surrogate
      }
    } else {
      len += 3;
    }
  }
  return len;
}
