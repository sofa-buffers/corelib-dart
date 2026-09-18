import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

Matcher _throwsCode(sofab.SofabError code) =>
    throwsA(isA<sofab.SofabException>().having((e) => e.code, 'code', code));

/// The `depth:` constructor option: the held-back sequence run is sized from
/// it at construction (CORELIB_PLAN §6.6), and never grown.
void main() {
  void build(sofab.Encoder e) {
    e.writeUnsigned(0, 1);
    e.beginSequenceLazy(10);
    e.beginSequenceLazy(11); // contentless: dropped
    e.endSequence();
    e.beginSequenceLazy(12);
    e.writeString(0, 'x');
    e.endSequence();
    e.endSequence();
  }

  Uint8List encode({int? depth}) {
    final buf = Uint8List(64);
    final e = depth == null
        ? sofab.Encoder.overBuffer(buf)
        : sofab.Encoder.overBuffer(buf, depth: depth);
    build(e);
    e.flush();
    return e.written;
  }

  test('a declared depth produces the same bytes as the default', () {
    expect(encode(depth: 2), equals(encode()));
    expect(encode(depth: sofab.maxDepth), equals(encode()));
  });

  test('opening more sequences than the declared depth is invalidArgument', () {
    expect(
      () => encode(depth: 1),
      _throwsCode(sofab.SofabError.invalidArgument),
    );
  });

  test('the default still refuses MAX_DEPTH + 1 as invalidMessage', () {
    final e = sofab.Encoder.overBuffer(Uint8List(16));
    for (var i = 0; i < sofab.maxDepth; i++) {
      e.beginSequenceLazy(0);
    }
    expect(
      () => e.beginSequenceLazy(0),
      _throwsCode(sofab.SofabError.invalidMessage),
    );
  });

  test('depth outside 1..MAX_DEPTH is refused at construction', () {
    for (final d in [0, -1, sofab.maxDepth + 1]) {
      expect(
        () => sofab.Encoder.overBuffer(Uint8List(8), depth: d),
        _throwsCode(sofab.SofabError.invalidArgument),
      );
      expect(
        () => sofab.Encoder((_) {}, buffer: Uint8List(64), depth: d),
        _throwsCode(sofab.SofabError.invalidArgument),
      );
    }
  });
}
