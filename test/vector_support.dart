import 'dart:convert';
import 'dart:typed_data';

import 'package:sofabuffers/sofabuffers.dart' as sofab;

/// Shared support for the conformance-vector tests.
///
/// The vector JSON carries full-range u64/i64 **integer literals** (up to
/// 2^64-1). Dart's `jsonDecode` silently degrades any integer above 2^63-1 to a
/// lossy `double`, so we cannot use it directly. Instead we wrap every bare
/// numeric token as a JSON string (respecting string literals + escapes) and
/// then parse each value exactly with `BigInt` / `double` at the point of use.

/// Wraps every bare JSON number token in [src] as a quoted string.
String wrapNumbers(String src) {
  final sb = StringBuffer();
  final n = src.length;
  var i = 0;
  var inStr = false;
  while (i < n) {
    final ch = src.codeUnitAt(i);
    if (inStr) {
      sb.writeCharCode(ch);
      if (ch == 0x5C && i + 1 < n) {
        // backslash escape: copy the escaped char verbatim
        sb.writeCharCode(src.codeUnitAt(i + 1));
        i += 2;
        continue;
      }
      if (ch == 0x22) inStr = false;
      i++;
      continue;
    }
    if (ch == 0x22) {
      inStr = true;
      sb.writeCharCode(ch);
      i++;
      continue;
    }
    final isDigit = ch >= 0x30 && ch <= 0x39;
    final isMinus = ch == 0x2D;
    if (isDigit || isMinus) {
      final start = i;
      i++;
      while (i < n) {
        final c = src.codeUnitAt(i);
        if ((c >= 0x30 && c <= 0x39) ||
            c == 0x2E || // .
            c == 0x2B || // +
            c == 0x2D || // -
            c == 0x65 || // e
            c == 0x45) {
          // E
          i++;
        } else {
          break;
        }
      }
      sb
        ..write('"')
        ..write(src.substring(start, i))
        ..write('"');
      continue;
    }
    sb.writeCharCode(ch);
    i++;
  }
  return sb.toString();
}

dynamic decodeVectorJson(String src) => jsonDecode(wrapNumbers(src));

/// A small integer (id / offset / length) — always within Dart int range.
int jInt(Object? x) => int.parse(x as String);

/// A full-range integer value or array element, returned as its int64 **bit
/// pattern** (so 2^64-1 becomes -1, matching what the encoder/decoder use).
int jU(Object? x) => BigInt.parse(x as String).toSigned(64).toInt();

/// A float value or element. Non-finite values arrive as the strings
/// `"inf"` / `"-inf"` (NaN is intentionally excluded from the vectors).
double jF(Object? x) {
  final s = x as String;
  if (s == 'inf') return double.infinity;
  if (s == '-inf') return double.negativeInfinity;
  return double.parse(s);
}

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(Uint8List b) {
  final sb = StringBuffer();
  for (final v in b) {
    sb.write(v.toRadix16Padded());
  }
  return sb.toString();
}

extension on int {
  String toRadix16Padded() => toRadixString(16).padLeft(2, '0');
}

/// Bit-pattern hex of an fp32 value (compare floats by bits, not `==`).
String fp32Hex(double v) {
  final bd = ByteData(4)..setFloat32(0, v, Endian.little);
  return bytesToHex(bd.buffer.asUint8List());
}

/// Bit-pattern hex of an fp64 value.
String fp64Hex(double v) {
  final bd = ByteData(8)..setFloat64(0, v, Endian.little);
  return bytesToHex(bd.buffer.asUint8List());
}

// --------------------------------------------------------------------------
// Encoding a vector's `fields` through the corelib encoder.
// --------------------------------------------------------------------------

Uint8List encodeFields(List<dynamic> fields, {int offset = 0}) {
  return sofab.Encoder.encodeToBytes((e) {
    for (final f in fields.cast<Map<String, dynamic>>()) {
      final op = f['op'] as String;
      switch (op) {
        case 'unsigned':
          e.writeUnsigned(jInt(f['id']), jU(f['value']));
          break;
        case 'signed':
          e.writeSigned(jInt(f['id']), jU(f['value']));
          break;
        case 'boolean':
          // In the wrapped JSON, `true`/`false` remain real booleans.
          e.writeBool(jInt(f['id']), f['value'] as bool);
          break;
        case 'fp32':
          e.writeFp32(jInt(f['id']), jF(f['value']));
          break;
        case 'fp64':
          e.writeFp64(jInt(f['id']), jF(f['value']));
          break;
        case 'string':
          e.writeString(jInt(f['id']), f['value'] as String);
          break;
        case 'blob':
          e.writeBlob(jInt(f['id']), hexToBytes(f['value_hex'] as String));
          break;
        case 'array':
          _encodeArray(e, f);
          break;
        case 'sequence_begin':
          e.beginSequence(jInt(f['id']));
          break;
        case 'sequence_end':
          e.endSequence();
          break;
        default:
          throw StateError('unknown op $op');
      }
    }
  }, offset: offset);
}

void _encodeArray(sofab.Encoder e, Map<String, dynamic> f) {
  final id = jInt(f['id']);
  final et = f['element_type'] as String;
  final values = f['values'] as List<dynamic>;
  if (et == 'fp32') {
    e.writeFp32Array(id, values.map(jF).toList());
  } else if (et == 'fp64') {
    e.writeFp64Array(id, values.map(jF).toList());
  } else if (et.startsWith('u')) {
    e.writeUnsignedArray(id, values.map(jU).toList());
  } else if (et.startsWith('i')) {
    e.writeSignedArray(id, values.map(jU).toList());
  } else {
    throw StateError('unknown element_type $et');
  }
}

// --------------------------------------------------------------------------
// Decoding: record events and compare against the expected `fields`.
// --------------------------------------------------------------------------

/// Canonical event keys expected from decoding a vector's dense bytes.
List<String> expectedEvents(List<dynamic> fields) {
  final out = <String>[];
  for (final f in fields.cast<Map<String, dynamic>>()) {
    final op = f['op'] as String;
    switch (op) {
      case 'unsigned':
        out.add('U:${jInt(f['id'])}:${jU(f['value'])}');
        break;
      case 'boolean':
        out.add('U:${jInt(f['id'])}:${(f['value'] as bool) ? 1 : 0}');
        break;
      case 'signed':
        out.add('S:${jInt(f['id'])}:${jU(f['value'])}');
        break;
      case 'fp32':
        out.add('F32:${jInt(f['id'])}:${fp32Hex(jF(f['value']))}');
        break;
      case 'fp64':
        out.add('F64:${jInt(f['id'])}:${fp64Hex(jF(f['value']))}');
        break;
      case 'string':
        out.add('STR:${jInt(f['id'])}:${f['value']}');
        break;
      case 'blob':
        out.add(
          'BLB:${jInt(f['id'])}:${(f['value_hex'] as String).toLowerCase()}',
        );
        break;
      case 'array':
        out.add(_expectedArray(f));
        break;
      case 'sequence_begin':
        out.add('SEQ:${jInt(f['id'])}');
        break;
      case 'sequence_end':
        out.add('END');
        break;
    }
  }
  return out;
}

String _expectedArray(Map<String, dynamic> f) {
  final id = jInt(f['id']);
  final et = f['element_type'] as String;
  final values = f['values'] as List<dynamic>;
  if (et == 'fp32') {
    return 'AF32:$id:${values.map((e) => fp32Hex(jF(e))).join(',')}';
  } else if (et == 'fp64') {
    return 'AF64:$id:${values.map((e) => fp64Hex(jF(e))).join(',')}';
  } else if (et.startsWith('u')) {
    return 'AU:$id:${values.map(jU).join(',')}';
  } else {
    return 'AI:$id:${values.map(jU).join(',')}';
  }
}

/// A [sofab.MessageVisitor] that records the canonical event key of every field
/// it is given, flattening nested sequences in wire order. Fields whose ids are
/// in [skipIds] are skipped at every level (never materialized/validated).
class RecordingVisitor extends sofab.MessageVisitor {
  RecordingVisitor({this.skipIds = const <int>{}});
  final Set<int> skipIds;
  final List<String> events = <String>[];

  @override
  bool shouldRead(int id, int type) => !skipIds.contains(id);

  @override
  void onUnsigned(int id, int value) => events.add('U:$id:$value');
  @override
  void onSigned(int id, int value) => events.add('S:$id:$value');
  @override
  void onFp32(int id, double value) => events.add('F32:$id:${fp32Hex(value)}');
  @override
  void onFp64(int id, double value) => events.add('F64:$id:${fp64Hex(value)}');
  @override
  void onString(int id, String value) => events.add('STR:$id:$value');
  @override
  void onBlob(int id, Uint8List value) =>
      events.add('BLB:$id:${bytesToHex(value)}');
  @override
  void onUnsignedArray(int id, Int64List values) =>
      events.add('AU:$id:${values.join(',')}');
  @override
  void onSignedArray(int id, Int64List values) =>
      events.add('AI:$id:${values.join(',')}');
  @override
  void onFp32Array(int id, Float32List values) =>
      events.add('AF32:$id:${values.map(fp32Hex).join(',')}');
  @override
  void onFp64Array(int id, Float64List values) =>
      events.add('AF64:$id:${values.map(fp64Hex).join(',')}');

  @override
  sofab.MessageVisitor? onSequenceStart(int id) {
    if (skipIds.contains(id)) return null; // skip the whole sub-sequence
    events.add('SEQ:$id');
    return this;
  }

  @override
  void onSequenceEnd() => events.add('END');
}

/// Expected events with the given ids (and their sub-sequences) removed —
/// mirrors what the skipping decoder should surface.
List<String> expectedEventsSkipping(List<dynamic> fields, Set<int> skipIds) {
  final out = <String>[];
  var suppressDepth = 0; // >0 while inside a skipped sub-sequence
  for (final f in fields.cast<Map<String, dynamic>>()) {
    final op = f['op'] as String;
    if (op == 'sequence_begin') {
      final id = jInt(f['id']);
      if (suppressDepth > 0) {
        suppressDepth++;
        continue;
      }
      if (skipIds.contains(id)) {
        suppressDepth = 1;
        continue;
      }
      out.add('SEQ:$id');
      continue;
    }
    if (op == 'sequence_end') {
      if (suppressDepth > 0) {
        suppressDepth--;
        continue;
      }
      out.add('END');
      continue;
    }
    if (suppressDepth > 0) continue;
    final id = jInt(f['id']);
    if (skipIds.contains(id)) continue;
    out.addAll(expectedEvents([f]));
  }
  return out;
}
