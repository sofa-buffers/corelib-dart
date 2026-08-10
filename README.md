<p align="center"><img src="assets/sofabuffers_logo.png" alt="SofaBuffers" height="140"></p>

# SofaBuffers

<b>Structured Objects For Anyone</b><br>
<i>... so optimized, feels amazing.</i>

[Would you like to know more?](https://github.com/sofa-buffers)

## SofaBuffers Dart library

[![CI](https://github.com/sofa-buffers/corelib-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/sofa-buffers/corelib-dart/actions/workflows/ci.yml)
[![coverage](https://sofa-buffers.github.io/corelib-dart/coverage.svg)](https://github.com/sofa-buffers/corelib-dart/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-API%20reference-blue)](https://sofa-buffers.github.io/corelib-dart/)

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
  a thin generated-object layer with one-line `encode()` / `decode()`
  helpers that *also* stream — see [`example/person.dart`](example/person.dart).
- **No runtime dependencies.** Pure Dart, `dart:core` + `dart:typed_data` only.

The public surface lives under the fixed `sofab` namespace (CORELIB_PLAN §6);
import it aliased.

### Requirements

- **Dart SDK ≥ 3.8.0** — the floor `pubspec.yaml` enforces
  (`environment: sdk: ^3.8.0`) and the lowest leg of the CI matrix, so it is
  also the oldest SDK this port is proven on.
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
| Streaming output | `Encoder` writes into a fixed `Uint8List` and invokes a `FlushCallback` when it fills; the buffer can be smaller than the message and swapped mid-stream (`installBuffer`). `Encoder.overBuffer` takes the same caller buffer **without** a sink: it holds the whole message (`written`) or reports `BufferFull`. |
| Streaming input | `Decoder.feed()` accepts any-size chunks; an explicit byte-state machine resumes across boundaries and returns the three-valued `DecodeStatus` — no finalize step. |
| Zero unnecessary copies | Flush hands out a `Uint8List.sublistView` of the live buffer; decoded blobs bind the payload buffer directly; string bytes are validated in place before one decode; a streamed `fp32`/`fp64` array is assembled *in* the typed list it is delivered as. |
| Low / no allocation on the hot path | Header/varint/array writes go straight to the buffer; `Encoder.reset()` reuses buffer + encoder across messages; typed-data (`Int64List`/`Float64List`) for arrays; a decoded `fp32`/`fp64` scalar stages in a reusable per-decoder slot, and an open sequence costs no object at all. |
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

### Sequences: lazy framing

A sequence-typed **field** whose value equals its declared default is *omitted*,
not written as an empty `begin`/`end` frame (MESSAGE_SPEC §2). Whether that is
the case depends on what the children turn out to be, while the header has to go
out before them — so `beginSequenceLazy` **holds the header back** and the first
field write commits it. Nothing is ever buffered: the held-back ids are encoder
state, so a tiny output buffer still produces the one-shot bytes.

The hold-back is **unbounded** — it reaches the format's full `MAX_DEPTH` of 255,
growing on demand and allocating nothing until the first sequence is opened — so
this port's output is canonical at *every* nesting level. (A fixed window with
eager framing beyond it is an allowance for heap-free profiles only;
CORELIB_PLAN §6, "How deep the hold-back reaches".)

```dart
sofab.Encoder.encodeToBytes((e) {
  e.beginSequenceLazy(1);
  e.endSequence();          // no content → emits NOTHING (not `0E 07`)
});

sofab.Encoder.encodeToBytes((e) {
  e.beginSequenceLazy(1);
  e.writeUnsigned(0, 42);   // content commits the held-back header
  e.endSequence();          // → 0E 00 2A 07, exactly the eager bytes
});

sofab.Encoder.encodeToBytes((e) {
  e.beginSequenceLazy(1);
  e.endSequenceKeep();      // frame forced out → 0E 07
});
```

Which closer to use is a static property of the schema position, not of the
value:

| position | closer |
|---|---|
| `struct` / `union` field | `endSequence` |
| array field (the wrapper) | `endSequence` |
| wrapper-array **element** (`struct`/`union`/nested row) | `endSequenceKeep` |
| array field known to differ from a **non-empty** declared `default` | `endSequenceKeep` |

`endSequenceKeep` is the safe default when in doubt: using it where
`endSequence` would do costs one non-canonical empty frame that every decoder
normalizes away, while the reverse silently changes a decoded array's **length**
(element presence is what carries it — MESSAGE_SPEC §5.1).

### Streaming a message larger than the buffer

Drive the flush callback with an output buffer smaller than the whole message;
the concatenated output is identical to the one-shot encoding.

```dart
final out = BytesBuilder();
final enc = sofab.Encoder(out.add, buffer: Uint8List(8)); // 8-byte buffer!
for (var i = 0; i < 1000; i++) {
  enc.writeUnsigned(i, i); // flushes repeatedly as it fills
}
enc.flush();
```

`sofab.minOutputBuffer` is how small "smaller" may get: this port's
`MIN_OUTPUT_BUFFER` (CORELIB_PLAN §5.1) is **1**, because the encoder splits
every atomic unit across a flush and reserves nothing contiguously. A buffer
handed over **with a sink** must leave at least that much room — `buffer.length -
offset >= sofab.minOutputBuffer` — and one byte less is rejected right where it
is handed over, with `SofabException(invalidArgument, …)`, by the constructor or
by `installBuffer`. See [Memory handling](#memory-handling).

#### Copying vs. taking sinks, and where the cursor resumes

What the callback does before it returns says which of the two handover shapes
is in effect (CORELIB_PLAN §5.1):

- **Returning without installing anything** means the sink **copied** the bytes.
  The active buffer stays active and the encoder refills it from offset **0**.
- A sink that **takes** the buffer — queues it for an async write, hands it to a
  transport — **must** call `installBuffer` before returning, or the encoder
  would keep writing into storage the transport now owns.

The start offset belongs to the *installation*, not to the buffer. Each
`installBuffer(buf, offset: n)` starts writing at byte `n` of `buf`, and that
offset is consumed by that installation only. Passing the **same** buffer back
counts as a new installation, which is how a sink re-arms framing-header room in
every flushed packet:

```dart
late sofab.Encoder enc;
enc = sofab.Encoder(
  (chunk) {
    socket.add(framed(chunk));            // fills the 4 reserved bytes
    enc.installBuffer(Uint8List(1024), offset: 4); // re-arms the reservation
  },
  buffer: Uint8List(1024),
  offset: 4,
);
```

The constructor's `offset` is the first installation and behaves the same way: a
callback that just returns resumes at 0, so a per-packet reservation has to be
re-armed per packet.

### A caller-supplied buffer with no sink

The other half of the §5.1 contract: hand over a buffer and *no* flush
callback. Nothing can be flushed, so the buffer either holds the whole message
— `written` gives it back as a view, no copy — or the write that runs out of
room throws `BufferFull`. This is the shape for a caller that sized its buffer
from a schema's `MAX_SIZE`, and for anyone who wants "here is my buffer, tell me
if it is too small" rather than a sink.

```dart
final buf = Uint8List(64);                        // sized from the schema
final enc = sofab.Encoder.overBuffer(buf, offset: 4); // 4 bytes framing room
enc.writeString(0, 'fits or throws');
enc.flush();                                      // no sink: a no-op
socket.add(enc.written);                          // exactly the message bytes
```

No minimum applies to a sink-less buffer — a minimum is a *streaming*
precondition and nothing streams here — so a two-byte message encodes into a
two-byte buffer, and one byte less reports `BufferFull` instead of silently
dropping the tail. `installBuffer` works in this mode too: take the bytes out of
the buffer you own, then install the next one.

### OStream (output-stream / writer sink)

The encoder *is* the ostream wrapper: a `FlushCallback` is any
`void Function(Uint8List)` sink — a `BytesBuilder.add`, an `IOSink`, a socket
write, etc.

```dart
final file = File('out.sofab').openWrite();
final enc = sofab.Encoder((chunk) => file.add(chunk), buffer: Uint8List(4096));
enc.writeString(0, 'streamed to disk');
enc.flush();
await file.close();
```

### IStream (input-stream / push-feed wrapper)

The decoder *is* the istream wrapper: push bytes as they arrive; each `feed`
returns the outcome so far. Suspending at any byte boundary is what the state
machine guarantees, not what it charges you for: whatever a chunk *does* hold
whole is taken whole — a varint is lifted out of it rather than accumulated a
byte at a time, a run of integer array elements is decoded 64 bits at a time by
the same reader the one-shot path uses, and an opaque payload is moved in one
copy — so feeding a message in a few large chunks costs close to what decoding
it in one piece costs, and only a field genuinely straddling a boundary falls
back to the per-byte path.

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
`encode()` / `decode()` **and** a streaming path. Both spellings come from the
closed name set of CORELIB_PLAN §6.1.1 — `encode()` / `decode(bytes)` for the
one-shot convenience, `serialize(ostream)` / `deserialize(istream)` for the
streaming pair beneath it, `decoder()` for the chunk reader — and the port adds
no second name for either pair, so the surface reads the same in every language.
See [`example/person.dart`](example/person.dart) for a complete, runnable
illustration:

```dart
final ada = Person()
  ..name = 'Ada'
  ..age = 36
  ..tags = ['pioneer', 'mathematician'];

final bytes = ada.encode();                 // one-shot
final back  = Person.decode(bytes);

// streaming out: your buffer, your sink, the same `serialize` the one-shot uses
final enc = sofab.Encoder(sink, buffer: Uint8List(4));
ada.serialize(enc);
enc.flush();

final dec = Person.decoder();               // streaming in
for (final b in bytes) dec.feed([b]);       // one byte at a time
final person = dec.value;                   // assembled incrementally
```

## Memory handling

Only two buffers matter — the one you encode into and the one you decode from —
and both are caller-owned. The two decode surfaces answer the ownership question
differently, so they get a row each.

| Buffer | Owner | Lifetime |
|--------|-------|----------|
| Output buffer (encode) | Caller — always | Reused after every flush; caller may swap it mid-stream. The flush view is valid only during the callback — copy to keep. |
| Input buffer, one-shot decode (`Decoder.decode`) | Caller | Must outlive the call **and every value kept from it**: delivered `blob` / `onStringBytes` values are zero-copy views into your buffer. Copy to retain. |
| Input chunk, streaming decode (`Decoder.feed`) | Caller | Reusable the moment `feed` returns. Nothing delivered aliases the chunk. |

- **The library allocates no output buffer** (CORELIB_PLAN §5.1). Every buffer
  the encoder writes into is one you handed over: `buffer:` is a **required**
  argument of the streaming constructor, and the only argument of
  `Encoder.overBuffer`. There is no size-only form that would allocate one for
  you — that would be a second ownership model, and §5.1 has just one. The layer
  that knows how big a message can get is the layer that allocates: normally the
  generated object, sizing from the schema (`MAX_SIZE` + `overBuffer` when the
  schema is bounded, a small scratch buffer + a sink when it is not) — see
  [`example/person.dart`](example/person.dart). `Encoder.encodeToBytes` is that
  layer in miniature: it allocates its scratch buffer once, explicitly, then
  drives the encoder like any other caller.
- **Output buffer (encoding).** You pass a `Uint8List`; the
  library never grows it. When it fills, the `FlushCallback` receives a
  `sublistView` of the written bytes and the encoder continues into the same
  buffer (or a new one you install). A buffer installed from inside the callback
  wins over the default rewind, so its `offset` — the framing-header room — is
  honoured on every installation, not just the first. If the buffer fills with no
  room after a flush, `writeX` throws `BufferFull` rather than overflowing.
  `Encoder.reset()` rewinds it for the next message.
- **`MIN_OUTPUT_BUFFER` = `sofab.minOutputBuffer` = 1.** The smallest buffer this
  port accepts for *streaming* (CORELIB_PLAN §5.1). It is 1 because the encoder
  splits every atomic unit — a field header, a `fixlen_word`, an
  `element_count`, a scalar or array-element varint, an `fp32`/`fp64` element —
  across a flush, so it never needs a contiguous reservation; a one-byte
  streaming buffer produces byte-identical output to the one-shot path. It binds
  a buffer installed **with a flush sink**, and only such a buffer: at
  construction and at every mid-stream `installBuffer`, `buffer.length - offset`
  must be at least `minOutputBuffer`, and a shortfall is rejected there with
  `SofabException(invalidArgument, …)` — the same mechanism as an out-of-range
  `offset`, never partway through a message. A buffer installed **without** a
  sink is subject to no minimum (next bullet).
- **Output buffer with no sink (`Encoder.overBuffer`).** The buffer is the only
  room there is: no flush can occur, nothing is handed downstream and nothing is
  ever dropped. A write that does not fit throws `BufferFull` — the encoder
  never reports partial output as complete — and `flush()` is a no-op that
  leaves the bytes where they are. `written` is a zero-copy view of the message
  inside your buffer, starting at the installation's `offset`, valid until the
  next write.
- **Input buffer, one-shot decode — zero-copy** (CORELIB_PLAN §9.6). You own the
  buffer you pass to `Decoder.decode`, and the decoder borrows it: `onBlob` and
  `onStringBytes` receive a `Uint8List` **view** onto your bytes, not a copy. The
  view is valid exactly as long as the buffer is alive and unmodified — a value
  kept past the visitor call moves with any later write into that buffer, so
  copy it (`Uint8List.fromList(value)`) to retain it. `onString` is the
  exception in the other direction: transcoding to a Dart `String` always
  copies, so that value is yours unconditionally. Passing a plain `List<int>`
  that is not a `Uint8List` copies it into one up front — the views then point
  into that private copy, and your list is untouched. Only `blob` and
  `onStringBytes` borrow: an array field is a freshly allocated typed list on
  either surface, and scalars are values.
- **Input chunk, streaming decode — copied out.** You own the chunks you feed
  and may reuse or overwrite each one the moment `feed` returns: a payload is
  reassembled into a library-owned carry buffer, so no delivered value ever
  aliases a fed chunk, however the chunk boundaries fall. The hot path allocates
  nothing for scalars — an `fp32`/`fp64` payload stages in a reusable slot the
  decoder owns for its lifetime — so that per-field carry buffer, for a `string`
  or `blob`, is the only library-owned heap. Values are delivered to your visitor
  at completion; copy them out if you need them past the callback. Feeding a
  plain `List<int>` that is not a `Uint8List` copies the chunk once up front,
  the same way `Decoder.decode` does.
- **A streamed array is never staged twice.** An `array<fp32>`/`array<fp64>`
  payload *is* the little-endian byte image of the `Float32List`/`Float64List`
  it decodes into, so a chunked decode has no carry buffer for it at all: the
  arriving bytes are written straight into the list that will be delivered.
  Peak memory is one array, whatever the chunking, and the elements are never
  copied or converted a second time — the streamed decode costs what the
  one-shot decode costs. Payload bytes (this and `string`/`blob` alike) are
  moved a chunk-run at a time rather than byte by byte, so a large payload
  arriving in reasonable chunks is a bulk copy, not a per-byte loop.
- **Array counts are never trusted for sizing.** On the one-shot surface
  (`Decoder.decode`) the whole message is in hand, so an `element_count` larger
  than the bytes that remain is already refuted by the input: the result is
  sized from what those bytes can actually hold, and the decode reports
  `incomplete`. A short message claiming `ARRAY_MAX` elements therefore costs an
  allocation on the order of the message, not of the count. When the input
  arrives in chunks the count cannot be refuted that way — there set
  `DecoderLimits(maxArrayCount: …)`, which is enforced at the count word,
  *before* the allocation it prevents (CORELIB_PLAN §6.2.1), and reports
  `limitExceeded`.
- **`DecoderLimits` is the *unbounded*-field backstop, and only that.** Its three
  caps are deployment policy, not schema validity: they protect the receiver from
  a field whose schema declares no `count:`/`maxlen:`, where the *sender* would
  otherwise dictate the allocation. §6.2.1 keeps them off the fields the schema
  already bounds — there the schema governs and a breach is `invalid`, never
  `limitExceeded`. Only the schema knows which fields those are, so a
  schema-bound (generated) consumer says so:

  ```dart
  @override
  int? onArrayCountBound(int id, sofab.ArrayKind kind) =>
      id == 3 && kind == sofab.ArrayKind.unsigned ? 8 : null;   // count: 8
  @override
  int? onFixlenLenBound(int id, int subtype) =>
      id == 1 && subtype == sofab.FixlenType.blob ? 64 : null;  // maxlen: 64
  ```

  For a field that answers, the declared bound *replaces* the cap: a wire
  count/length past it is `invalid` (decided at the count/length word, before the
  allocation), and one within it decodes however tight the cap is.
  `kind`/`subtype` are what the **wire** declares — return `null` for one the
  field does not declare, since that is a MESSAGE_SPEC §7.3 skip and no schema
  bound covers it. Both hooks are asked at most once per field and only once a
  cap has actually been exceeded, so a decode with no `DecoderLimits` never calls
  them. `onFixlenHeader`/`onArrayBegin` fire *before* the cap is weighed either
  way, so a consumer that enforces its bound there always sees the header.

## Build & test

```console
dart pub get
dart analyze --fatal-infos      # build: no errors
dart test                       # runs the shared vectors + streaming/malformed/truncation
dart run example/person.dart    # the generated-object demo
bash bench/run_bench.sh         # release build: `dart compile exe` (AOT) + run
```

The test suite reads the shared conformance vectors from
[`assets/test_vectors.json`](assets/test_vectors.json) (generated by, and copied
verbatim from, `corelib-c-cpp`) and runs encode, decode, chunked-encode,
chunked-decode, skip-ids, roundtrip, malformed-input, truncation and invalid-UTF-8
checks. CI enforces the >90% line-coverage bar (CORELIB_PLAN §7.3); the rendered
coverage badge is generated from the lcov report and published to GitHub Pages by
the docs workflow.

Both configurations are built (CORELIB_PLAN §12.1). For Dart, `dart run` and
`dart test` *are* the debug (JIT) configuration; the release configuration is
AOT, i.e. `dart compile exe`. Every matrix leg runs the JIT steps above, and the
`stable` leg additionally runs `bench/run_bench.sh` and `bench/run_callgrind.sh`
— between them they AOT-compile every entrypoint this repository ships and run
the result, so an AOT-only failure cannot ship unnoticed. Compiled output lands
in `build/`, which is git-ignored and must never be committed.

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
