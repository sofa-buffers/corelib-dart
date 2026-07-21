<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

A part of the [SofaBuffers](https://github.com/sofa-buffers) project — a compact,
self-describing, fully **streamable** binary serialization format.

## SofaBuffers Dart library

[![CI](https://github.com/sofa-buffers/corelib-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/sofa-buffers/corelib-dart/actions/workflows/ci.yml)
[![coverage](https://sofa-buffers.github.io/corelib-dart/coverage.svg)](https://sofa-buffers.github.io/corelib-dart/)
[![Docs](https://img.shields.io/badge/docs-API%20reference-blue)](https://sofa-buffers.github.io/corelib-dart/)

**Repository:** <https://github.com/sofa-buffers/corelib-dart> · **Org:** <https://github.com/sofa-buffers>

`corelib-dart` is the high-speed Dart implementation of SofaBuffers. It encodes and
decodes the exact same bytes as every other port and is validated against the
shared, language-agnostic conformance vectors. What makes it worth reaching for:

- **Truly streaming, both directions.** Encode into a buffer far smaller than the
  message (a flush callback drains it) and decode by feeding **arbitrarily small
  chunks** — one byte at a time if you like. The decoder's state machine suspends
  and resumes at any byte boundary, so an object larger than memory still
  assembles field-by-field.
- **Fast, allocation-light hot path.** Scalars, headers and array elements are
  written straight into a caller-owned `Uint8List`; the encoder can be reset and
  reused across messages with zero per-message allocation. Integers use
  variable-length varints so common small values cost a single byte.
- **Cross-language compatible.** Byte-for-byte identical to `corelib-rs`,
  `corelib-c-cpp`, `corelib-go`, and the rest of the family.
- **Dead-simple generated objects.** The streaming primitives are enough to build
  a thin generated-object layer with one-line `serialize()` / `deserialize()`
  helpers that *also* stream — see [`example/person.dart`](example/person.dart).
- **No runtime dependencies.** Pure Dart, `dart:core` + `dart:typed_data` only.

The public surface lives under the fixed `sofab` namespace (CORELIB_PLAN §6);
import it aliased.

### Requirements

- **Dart SDK ≥ 3.4.0.**
- Install:

  ```console
  dart pub add sofabuffers
  ```

  > The package is `SofaBuffers` conceptually, but pub.dev requires
  > lowercase-with-underscores names, so the published name is **`sofabuffers`**.
  > You install `sofabuffers` and import it as `sofab`.

### Dependencies

**No runtime dependencies.** Dev-only: `test`, `coverage`, `lints`.

## Why this design

| Design goal | How `corelib-dart` achieves it |
|-------------|--------------------------------|
| Streaming output | `Encoder` writes into a fixed `Uint8List` and invokes a `FlushCallback` when it fills; the buffer can be smaller than the message and swapped mid-stream (`installBuffer`). |
| Streaming input | `Decoder.feed()` accepts any-size chunks; an explicit byte-state machine resumes across boundaries and returns the three-valued `DecodeStatus` — no finalize step. |
| Zero unnecessary copies | Flush hands out a `Uint8List.sublistView` of the live buffer; decoded blobs bind the payload buffer directly; string bytes are validated in place before one decode. |
| Low / no allocation on the hot path | Header/varint/array writes go straight to the buffer; `Encoder.reset()` reuses buffer + encoder across messages; typed-data (`Int64List`/`Float64List`) for arrays. |
| Small, predictable footprint | One tiny per-field carry buffer for chunk-straddling payloads; no reflection, no codegen at runtime. |
| Type safety | Typed `write*` methods and a typed `MessageVisitor`; `SofabException` carries a `SofabError` code, `Decoder` reports `DecodeStatus`. |
| Cross-language compatibility | Validated against the shared `assets/test_vectors.json` for encode, decode, chunked, skip and roundtrip. |

## Usage

Import aliased to the `sofab` namespace:

```dart
import 'package:sofabuffers/sofabuffers.dart' as sofab;
```

### Simple encode

```dart
final bytes = sofab.Encoder.encodeToBytes((e) {
  e.writeUnsigned(1, 0xDEADBEEF);
  e.writeSigned(2, -12345);
  e.writeBool(3, true);
  e.writeString(5, 'sofab');
  e.writeUnsignedArray(6, const [10, 20, 30, 40]);
});
```

### Simple decode

```dart
class MyVisitor extends sofab.MessageVisitor {
  @override
  void onUnsigned(int id, int value) => print('u[$id] = $value');
  @override
  void onString(int id, String value) => print('s[$id] = $value');
}

final status = sofab.Decoder.decode(bytes, MyVisitor());
assert(status == sofab.DecodeStatus.complete);
```

### Streaming a message larger than the buffer

Drive the flush callback with an output buffer smaller than the whole message;
the concatenated output is identical to the one-shot encoding.

```dart
final out = BytesBuilder();
final enc = sofab.Encoder(out.add, bufferSize: 8); // 8-byte buffer!
for (var i = 0; i < 1000; i++) {
  enc.writeUnsigned(i, i); // flushes repeatedly as it fills
}
enc.flush();
```

### OStream (output-stream / writer sink)

The encoder *is* the ostream wrapper: a `FlushCallback` is any
`void Function(Uint8List)` sink — a `BytesBuilder.add`, an `IOSink`, a socket
write, etc.

```dart
final file = File('out.sofab').openWrite();
final enc = sofab.Encoder((chunk) => file.add(chunk), bufferSize: 4096);
enc.writeString(0, 'streamed to disk');
enc.flush();
await file.close();
```

### IStream (input-stream / push-feed wrapper)

The decoder *is* the istream wrapper: push bytes as they arrive; each `feed`
returns the outcome so far.

```dart
final dec = sofab.Decoder(MyVisitor());
await for (final chunk in socket) {
  final status = dec.feed(chunk);
  if (status == sofab.DecodeStatus.invalid) throw 'malformed';
}
// status == complete once the message boundary is reached.
```

### Generator (generated objects — the common case)

Generated objects hide ids, varints and buffers entirely, offering one-line
`serialize()` / `deserialize()` **and** a streaming path. See
[`example/person.dart`](example/person.dart) for a complete, runnable illustration:

```dart
final ada = Person()
  ..name = 'Ada'
  ..age = 36
  ..tags = ['pioneer', 'mathematician'];

final bytes = ada.serialize();              // one-shot
final back  = Person.deserialize(bytes);

ada.serializeTo(sink, bufferSize: 4);       // streaming out, tiny buffer
final dec = Person.decoder();               // streaming in
for (final b in bytes) dec.feed([b]);       // one byte at a time
final person = dec.value;                   // assembled incrementally
```

## Memory handling

Only two buffers matter, and both are caller-visible.

| Buffer | Owner | Lifetime |
|--------|-------|----------|
| Output buffer (encode) | Caller (or the encoder allocates a default) | Reused after every flush; caller may swap it mid-stream. The flush view is valid only during the callback — copy to keep. |
| Input bytes (decode) | Caller | Must outlive the `feed` call. Decoded `blob` values may reference a freshly-allocated payload buffer; `string` values are fresh Dart strings. |

- **Output buffer (encoding).** You pass a `Uint8List` (or a `bufferSize`); the
  library never grows it. When it fills, the `FlushCallback` receives a
  `sublistView` of the written bytes and the encoder continues into the same
  buffer (or a new one you install). If the buffer fills with no room after a
  flush, `writeX` throws `BufferFull` rather than overflowing. `Encoder.reset()`
  rewinds it for the next message.
- **Input buffer (decoding).** You own the chunks you feed. The hot path
  allocates nothing for scalars; the only library-owned heap is a small per-field
  carry buffer used to reassemble a `string`/`blob`/float payload that straddles a
  chunk boundary. Decoded values are delivered to your visitor at completion —
  copy them out if you need them past the callback.

## Build & test

```console
dart pub get
dart analyze --fatal-infos      # build: no errors
dart test                       # runs the shared vectors + streaming/malformed/truncation
dart run example/person.dart    # the generated-object demo
```

The test suite reads the shared conformance vectors from
[`assets/test_vectors.json`](assets/test_vectors.json) (generated by, and copied
verbatim from, `corelib-c-cpp`) and runs encode, decode, chunked-encode,
chunked-decode, skip-ids, roundtrip, malformed-input, truncation and invalid-UTF-8
checks. CI enforces the >90% line-coverage bar (CORELIB_PLAN §7.3); the rendered
coverage badge is generated from the lcov report and published to GitHub Pages by
the docs workflow.

## Benchmarks

Three tools, following the cross-language [`BENCH_SPEC.md`](https://github.com/sofa-buffers/documentation/blob/main/BENCH_SPEC.md):

```console
bash  bench/run_bench.sh         # AOT-native throughput + per-op (recommended)
bash  bench/run_callgrind.sh     # Callgrind Ir/op (instructions retired per op)

# Quick JIT variants (no compile step, but slower / with VM warmup):
dart run bench/bench.dart        # throughput (MB/s) over a ~1s CPU-time loop
dart run bench/perf.dart         # per-op cost for the 170-byte perf message
```

> **Run the benchmarks AOT-compiled** (`bench/run_bench.sh` uses
> `dart compile exe`) for representative numbers — it removes JIT warmup and is
> the fair comparison to the compiled ports (C/C++/Rust/Go), which also run
> native. On the same machine, AOT is roughly 2× the JIT throughput on the
> small-message workloads. `run_callgrind.sh` already builds an AOT target.

- **`bench`** — practical throughput on *this* machine, in MB/s, for encode and
  decode of the `u64 array (1000)` and `typical` workloads.
- **`perf`** — per-op cost of serialize/deserialize. The Dart VM exposes no
  hardware cycle counter, so `cycles/op` is reported as unavailable and CPU
  time/op (from `/proc/self/stat`) is the machine-neutral-ish signal.
- **`run_callgrind.sh`** — instructions-per-op under Callgrind: deterministic and
  machine-independent, the right signal for a CI performance-regression gate. It
  uses the **two-rep subtraction** method (Dart has no stable per-workload native
  symbol to toggle), running an AOT-compiled target at two rep counts and
  subtracting to cancel startup and setup cost.
