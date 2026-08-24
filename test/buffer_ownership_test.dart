@TestOn('vm')
library;

import 'dart:mirrors';
import 'dart:typed_data';

import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
import 'package:test/test.dart';

import 'vector_support.dart';

/// A payload several times longer than the tiny buffers below, so the flush
/// path runs many times and every handover is observed.
void _build(sofab.Encoder e) {
  for (var i = 0; i < 8; i++) {
    e.writeUnsigned(i, 0x1122334455667788);
  }
  e.writeString(9, 'the payload outruns the buffer several times over');
  e.beginSequenceLazy(10);
  e.writeSigned(0, -12345);
  e.endSequence();
}

/// Whether [view] is a window onto [owner]'s storage rather than a copy the
/// corelib made. `Uint8List.buffer` hands back a fresh wrapper object each time,
/// so identity has to be established through the bytes: poke [owner] and see
/// whether [view] shows the poke.
bool _aliases(Uint8List view, Uint8List owner) {
  if (view.isEmpty) return true;
  final at = view.offsetInBytes - owner.offsetInBytes;
  if (at < 0 || at >= owner.length) return false;
  final saved = owner[at];
  owner[at] = saved ^ 0xFF;
  final aliased = view[0] == (saved ^ 0xFF);
  owner[at] = saved;
  return aliased;
}

void main() {
  final oneShot = sofab.Encoder.encodeToBytes(_build);

  // CORELIB_PLAN §5.1, "A corelib MUST NOT allocate an output buffer. Every
  // buffer the encoder writes into is caller-supplied." — the storage comes
  // from the caller (in the normal case, from the generated layer, which knows
  // the schema); there is one buffer-ownership model, not two.
  group('CORELIB_PLAN §5.1 buffer ownership', () {
    final constructors = reflectClass(sofab.Encoder).declarations.values
        .whereType<MethodMirror>()
        .where((m) => m.isConstructor)
        .toList();

    test('every constructor takes a caller-supplied buffer', () {
      expect(constructors, isNotEmpty);
      for (final c in constructors) {
        final name = MirrorSystem.getName(c.simpleName);
        expect(
          c.parameters.any(
            (p) => MirrorSystem.getName(p.type.simpleName) == 'Uint8List',
          ),
          isTrue,
          reason: 'Encoder.$name must accept a caller-supplied Uint8List',
        );
      }
    });

    test('no constructor offers a size to allocate from', () {
      // A size-only knob *is* the second ownership model: it can only be
      // honoured by allocating, which is exactly what §5.1 forbids.
      const sizeKnobs = {'bufferSize', 'capacity', 'size'};
      for (final c in constructors) {
        final name = MirrorSystem.getName(c.simpleName);
        final params = c.parameters
            .map((p) => MirrorSystem.getName(p.simpleName))
            .toSet();
        expect(
          params.intersection(sizeKnobs),
          isEmpty,
          reason: 'Encoder.$name must not size a buffer of its own',
        );
      }
    });

    test('an encoder cannot be constructed without handing one over', () {
      // The streaming constructor's buffer is *required*: leaving it out is a
      // missing argument, not an invitation to allocate a default.
      final cls = reflectClass(sofab.Encoder);
      void sink(Uint8List chunk) {}
      expect(
        () => cls.newInstance(const Symbol(''), <Object?>[sink]),
        throwsA(isA<Error>()),
      );
      // Handing one over is all it takes.
      expect(
        cls
            .newInstance(
              const Symbol(''),
              <Object?>[sink],
              {#buffer: Uint8List(32)},
            )
            .reflectee,
        isA<sofab.Encoder>(),
      );
    });

    test('the encoder writes only into the buffer it was handed', () {
      final buf = Uint8List(16);
      final out = BytesBuilder(copy: true);
      var flushes = 0;
      var foreign = 0;
      final enc = sofab.Encoder((chunk) {
        flushes++;
        if (!_aliases(chunk, buf)) foreign++;
        out.add(chunk);
      }, buffer: buf);
      _build(enc);
      expect(_aliases(enc.written, buf), isTrue);
      enc.flush();
      expect(flushes, greaterThan(1), reason: 'the buffer must have filled');
      expect(foreign, 0, reason: 'no chunk may come from corelib storage');
      // "grow or reallocate a buffer the caller supplied" is forbidden too.
      expect(buf.length, 16);
      expect(bytesToHex(out.toBytes()), bytesToHex(oneShot));
    });

    test('the one-shot helper is a caller like any other', () {
      // §5.1 permits exactly one allocation site above the corelib's write
      // path: the one-shot convenience allocates once, explicitly, and then
      // drives the encoder over that buffer like any other caller — so its
      // bytes are the streaming bytes.
      final buf = Uint8List(64);
      final out = BytesBuilder(copy: true);
      final enc = sofab.Encoder(out.add, buffer: buf);
      _build(enc);
      enc.flush();
      expect(bytesToHex(oneShot), bytesToHex(out.toBytes()));
    });
  });
}
