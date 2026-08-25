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
shared, language-agnostic conformance vectors.

- **Truly streaming, both directions.** Encode into a buffer far smaller than the
  message (a flush callback drains it) and decode by feeding **arbitrarily small
  chunks** — one byte at a time if you like. The decoder's state machine suspends
  and resumes at any byte boundary.
- **Fast, allocation-light hot path.** Scalars, headers and array elements are
  written straight into a caller-owned `Uint8List`; the encoder can be reset and
  reused across messages with zero per-message allocation. Integers use
  variable-length varints, so common small values cost a single byte.
- **Cross-language compatible.** Byte-for-byte identical to `corelib-rs`,
  `corelib-c-cpp`, `corelib-go`, and the rest of the family.
- **Dead-simple generated objects.** A thin layer with one-line `encode()` /
  `decode()` helpers that *also* stream — see
  [`example/person.dart`](example/person.dart).
- **No runtime dependencies.** Pure Dart, `dart:core` + `dart:typed_data` only.

The public surface lives under the fixed `sofab` namespace; import it aliased.

### Requirements

- **Dart SDK ≥ 3.8.0** — the floor `pubspec.yaml` enforces
  (`environment: sdk: ^3.8.0`) and the lowest leg of the CI matrix.
- Install:

  ```console
  dart pub add sofa_buffers_corelib
  ```

  > The published name is **`sofa_buffers_corelib`** — the organization slug
  > `sofa-buffers` plus `corelib`, in pub.dev's required
  > lowercase-with-underscores form. You install `sofa_buffers_corelib` and
  > import it as `sofab`.

### Dependencies

**No runtime dependencies.** Dev-only: `test`, `coverage`, `lints`.

## Why this design

| Design goal | How `corelib-dart` achieves it |
|-------------|--------------------------------|
| Streaming output | `Encoder` writes into a fixed `Uint8List` and invokes a `FlushCallback` when it fills; the buffer can be smaller than the message and swapped mid-stream (`installBuffer`). `Encoder.overBuffer` takes the same caller buffer **without** a sink: it holds the whole message (`written`) or reports `BufferFull`. |
| Streaming input | `Decoder.feed()` accepts any-size chunks; an explicit byte-state machine resumes across boundaries and returns the three-valued `DecodeStatus` — no finalize step. |
| Zero unnecessary copies | Flush hands out a `Uint8List.sublistView` of the live buffer; a payload is written once, straight into the destination its reader supplied — including a string transcoded on encode, which goes into the output buffer rather than through one of its own; an `fp32`/`fp64` array is decoded *in* the typed list it is delivered as. |
| No allocation on the hot path | Header/varint/array writes go straight to the caller's buffer; every decoded payload goes straight into the caller's destination; `Encoder.reset()` reuses buffer + encoder across messages; a decoded `fp32`/`fp64` scalar stages in a reusable per-decoder slot, and an open sequence costs no object at all. |
| Small, predictable footprint | Codec state is one `MAX_DEPTH` run plus an 8-byte landing zone per side, sized in the constructor and never grown; no reflection, no codegen at runtime. |
| Type safety | Typed `write*` methods and a typed `MessageVisitor`; `SofabException` carries a `SofabError` code, `Decoder` reports `DecodeStatus`. |
| Cross-language compatibility | Validated against the shared `assets/test_vectors.json` for encode, decode, chunked, skip and roundtrip. |

## Usage

Import aliased to the `sofab` namespace:

```dart
import 'package:sofa_buffers_corelib/sofa_buffers_corelib.dart' as sofab;
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

Dart's only floating type is `double`, so an `fp32` **NaN** arrives as raw bits:
`onFp32Bits(id, bits)` carries the 32-bit IEEE-754 pattern, and its default
widens to `onFp32`. Re-emit those bits with `Encoder.writeFp32Bits` — widening
quiets a signaling NaN, and the wire bytes must round-trip unchanged
(CORELIB_PLAN §6.5). An `fp32` **array** needs nothing extra: it is delivered as
a `Float32List` and `writeFp32Array` re-emits that list's bytes verbatim.

### Sequences: lazy framing

A sequence-typed **field** whose value equals its declared default is *omitted*,
not written as an empty `begin`/`end` frame (MESSAGE_SPEC §2). `beginSequenceLazy`
**holds the header back** and the first field write commits it. Nothing is ever
buffered — the held-back ids are encoder state, so a tiny output buffer still
produces the one-shot bytes.

The hold-back is **unbounded**: it reaches the format's full `MAX_DEPTH` of 255,
growing on demand and allocating nothing until the first sequence is opened.

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
normalizes away, while the reverse silently changes a decoded array's **length**.

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
`MIN_OUTPUT_BUFFER` is **1**. A buffer handed over **with a sink** must leave at
least that much room — `buffer.length - offset >= sofab.minOutputBuffer` — and
one byte less is rejected right where it is handed over, with
`SofabException(invalidArgument, …)`, by the constructor or by `installBuffer`.
See [Memory handling](#memory-handling).

#### Copying vs. taking sinks, and where the cursor resumes

What the callback does before it returns says which of the two handover shapes
is in effect:

- **Returning without installing anything** means the sink **copied** the bytes.
  The active buffer stays active and the encoder refills it from offset **0**.
- A sink that **takes** the buffer — queues it for an async write, hands it to a
  transport — **must** call `installBuffer` before returning.

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

Hand over a buffer and *no* flush callback. Nothing can be flushed, so the
buffer either holds the whole message — `written` gives it back as a view, no
copy — or the write that runs out of room throws `BufferFull`.

```dart
final buf = Uint8List(64);                        // sized from the schema
final enc = sofab.Encoder.overBuffer(buf, offset: 4); // 4 bytes framing room
enc.writeString(0, 'fits or throws');
enc.flush();                                      // no sink: a no-op
socket.add(enc.written);                          // exactly the message bytes
```

No minimum applies to a sink-less buffer: a two-byte message encodes into a
two-byte buffer, and one byte less reports `BufferFull` instead of silently
dropping the tail. `installBuffer` works in this mode too — take the bytes out of
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
returns the outcome so far. Whatever a chunk holds whole is taken whole — a
varint is lifted out of it rather than accumulated a byte at a time, a run of
integer array elements is decoded 64 bits at a time by the same reader the
one-shot path uses, and an opaque payload is moved in one copy. Only a field
genuinely straddling a boundary falls back to the per-byte path.

```dart
final dec = sofab.Decoder(MyVisitor());
await for (final chunk in socket) {
  final status = dec.feed(chunk);
  if (status == sofab.DecodeStatus.invalid) throw 'malformed';
}
// status == complete once the message boundary is reached.
```

### Generator (generated objects — the common case)

Generated objects hide ids, varints and buffers entirely: `encode()` /
`decode(bytes)` for the one-shot convenience, `serialize(ostream)` /
`deserialize(istream)` for the streaming pair beneath it, and `decoder()` for
the chunk reader. See [`example/person.dart`](example/person.dart) for a
complete, runnable illustration:

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

#### What generated code builds on

Four pieces of that layer live here rather than in every generated file — none
of them knows a schema.

| symbol | what it is for |
|---|---|
| `sofab.VisitorBase` | the visitor base a generated scope extends: an id the scope does not declare is *skipped*, not inspected, for strings (`onStringBytes`) and sub-sequences (`onSequenceStart`) alike |
| `sofab.decodeUtf8Strict` | materializes a `string` payload, or `null` if it is not valid UTF-8 — one scan with an ASCII fast path, the decode-side twin of `encodeUtf8Strict` |
| `sofab.utf8Length` | the exact UTF-8 byte length of a `String`, without allocating the transcode buffer |
| `sofab.elementsEqual` | pairwise list comparison, which is how a generated encoder asks whether a list field still equals its declared default (`==` on two Dart `List`s is identity) |

```dart
// A generated scope: one string destination at id 1, everything else skipped.
class _Scope extends sofab.VisitorBase {
  String? name;
  bool invalid = false;

  @override
  void onStringBytes(int id, Uint8List bytes) {
    if (id != 1) return;                    // falls through to the base's skip
    final s = sofab.decodeUtf8Strict(bytes);
    if (s == null) {
      invalid = true;                       // the consumer's sticky INVALID
      return;
    }
    name = s;
  }
}
```

`MessageVisitor`'s own defaults are the opposite — read everything, descend
every sequence. A payload a visitor does not bind is a skipped field, and a
skipped field is never UTF-8-validated.

## Memory handling

Only two buffers matter — the one you encode into and the one you decode from —
and both are caller-owned. The library owns neither, on either decode surface.

| Buffer | Owner | Lifetime |
|--------|-------|----------|
| Output buffer (encode) | Caller — always | Reused after every flush; caller may swap it mid-stream. The flush view is valid only during the callback — copy to keep. |
| Input buffer, one-shot decode (`Decoder.decode`) | Caller | Must outlive the call. Nothing delivered aliases it. |
| Input chunk, streaming decode (`Decoder.feed`) | Caller | Reusable the moment `feed` returns. Nothing delivered aliases the chunk. |
| Every decoded value | Caller | Written into a destination you supplied, and yours for as long as you keep it. |

- **The library allocates no output buffer.** Every buffer the encoder writes
  into is one you handed over: `buffer:` is a **required** argument of the
  streaming constructor, and the only argument of `Encoder.overBuffer`. There is
  no size-only form that allocates one for you. The layer that knows how big a
  message can get is the layer that allocates — normally the generated object,
  sizing from the schema (`MAX_SIZE` + `overBuffer` when the schema is bounded,
  a small scratch buffer + a sink when it is not); see
  [`example/person.dart`](example/person.dart).
- **Output buffer (encoding).** You pass a `Uint8List`; the library never grows
  it. When it fills, the `FlushCallback` receives a `sublistView` of the written
  bytes and the encoder continues into the same buffer (or a new one you
  install). A buffer installed from inside the callback wins over the default
  rewind, so its `offset` — the framing-header room — is honoured on every
  installation, not just the first. If the buffer fills with no room after a
  flush, `writeX` throws `BufferFull` rather than overflowing.
  `Encoder.reset()` rewinds it for the next message.
- **A sink is only ever handed memory inside the installed buffer.**
  Pass-through is forbidden: however large a `string` or `blob` you write, its
  bytes travel through the output buffer like everything else, so a flush
  callback has exactly one case to handle. There is no permission that
  reinstates it.
- **`MIN_OUTPUT_BUFFER` = `sofab.minOutputBuffer` = 1.** The smallest buffer
  this port accepts for *streaming*, and a one-byte streaming buffer produces
  byte-identical output to the one-shot path. It binds a buffer installed **with
  a flush sink**, and only such a buffer: at construction and at every
  mid-stream `installBuffer`, `buffer.length - offset` must be at least
  `minOutputBuffer`, and a shortfall is rejected there with
  `SofabException(invalidArgument, …)`, never partway through a message. A
  buffer installed **without** a sink is subject to no minimum.
- **Output buffer with no sink (`Encoder.overBuffer`).** The buffer is the only
  room there is: no flush can occur, nothing is handed downstream and nothing is
  ever dropped. A write that does not fit throws `BufferFull`, and `flush()` is
  a no-op that leaves the bytes where they are. `written` is a zero-copy view of
  the message inside your buffer, starting at the installation's `offset`, valid
  until the next write.
- **Input bytes (decoding).** You own them, and they must stay alive for the
  duration of the call you hand them to — `feed(chunk)` or `decode(buffer)` —
  and no longer. Both surfaces are the same in this: the moment the call
  returns, the bytes are yours to reuse, overwrite or free, and nothing the
  decoder delivered changes.
- **No wire value decides an allocation in the library.** No count, length or
  payload on the wire sizes anything the codec takes, on the one-shot path
  exactly as on the streaming one. There is **no library-owned accumulator for
  a chunk-straddling field**: a `string` or `blob` split across `feed` calls is
  joined in *your* destination, one piece per call.
- **Every decoded value lands in a destination you supply.** The decoder asks
  for it at the header that announces the size — `onBytesDest(id, subtype,
  total)` for a `string`/`blob`, `onArrayDest(id, kind, count)` for an array —
  and writes into what you hand back. Returning a list shorter than announced,
  or of the wrong element type, fails the decode with
  `SofabException(invalidArgument, …)`: the decoder never grows what it was
  given. Returning `null` declines the field, which is then walked like a
  skipped one.

  The `MessageVisitor` defaults allocate an exactly-sized destination per field
  and forward it to `onString`, `onStringBytes`, `onBlob` and the four
  whole-array callbacks, so a hand-written visitor needs none of this. That
  allocation is **yours**, made inside a callback: override the two `…Dest`
  hooks with storage you own — a record's own list, a pooled buffer — and the
  decode allocates nothing at all.
- **Nothing outlives the callback.** What a callback receives is valid until it
  returns; a value you keep, you keep because the storage was yours to begin
  with. There is no payload-position getter and no "valid until the next feed"
  value, on either surface. `onString` is the one value the library materializes
  for you — transcoding to a Dart `String` always copies — and it is
  unconditionally yours.
- **The library's own state is sized once, in the constructor.** An `Encoder`
  holds a `MAX_DEPTH`-entry pending-sequence run and an 8-byte float landing
  zone; a `Decoder` holds a `MAX_DEPTH`-entry parse stack and its own 8-byte
  landing zone. None of them grows, and none of them is sized by anything on the
  wire. An open sequence costs no object at all, and an `fp32`/`fp64` scalar
  stages in that landing zone rather than in a per-field buffer.
- **The typed-data handles the language forces, in full.** Dart's bulk-copy and
  float primitives take a view object rather than a pointer and a length, so the
  codec allocates these — each a fixed-size wrapper over memory *you* own, whose
  cost is the same for ten bytes as for ten megabytes:

  | handle | when |
  |---|---|
  | `Uint8List.sublistView` of the output buffer | once per flush, and once per `written` |
  | `ByteData.sublistView` of the output buffer | once per buffer installation |
  | `String.codeUnits` | once per non-ASCII `writeString` |
  | `ByteData.sublistView` of a fed chunk | at most once per `feed`, and only for a chunk carrying integer-array elements |
  | `Uint8List.sublistView` of an array destination | once per `fp32`/`fp64` array field |
  | `ByteData.view` of the input buffer | once per `Decoder.decode` that reads an array |

  `bench/alloc_profile.dart` measures what is left, and
  `test/alloc_profile_test.dart` gates it: a 16-byte and a 4096-byte payload of
  the same field shape must cost the same.
- **The collectors beside the codec are the generated layer's, and they
  allocate.** `StringSeq`, `BlobSeq`, `MessageSeq`, `NestedSeq`, `IntMatrixSeq`,
  `DoubleMatrixSeq` and `BoolMatrixSeq` build a wrapper array's container as its
  elements arrive — the one place where growing is right, because a wrapper
  array has no count on the wire and its length is *highest present id + 1*.
  They are helpers the generated layer reaches through the visitor, not part of
  the codec. Their growth is `List.add`'s, which doubles, so filling a gap of
  *n* costs O(*n*) amortised rather than O(*n*²) — **untested**: Dart offers no
  in-process allocation counter fine enough to assert a growth geometry, so this
  is stated here rather than reported as a covered case.
- **`DecoderLimits` is the *unbounded*-field backstop, and only that.** Its
  three caps are deployment policy, not schema validity: they apply to a field
  whose schema declares no `count:`/`maxlen:`, and never to a field the schema
  already bounds — there a breach is `invalid`, never `limitExceeded`. All three
  are finite and there is no way to say "unlimited": an unconfigured `Decoder`
  carries `sofab.defaultMaxDynArrayCount` (2²⁰ elements),
  `sofab.defaultMaxDynStringLen` (16 MiB) and `sofab.defaultMaxDynBlobLen`
  (64 MiB). A wrapper array's element **index** is bounded the same way, by the
  collectors' `rcap`, because the index is what the array's length is.

  Only the schema knows which fields the caps must stay off, so a schema-bound
  (generated) consumer says so:

  ```dart
  @override
  int? onArrayCountBound(int id, sofab.ArrayKind kind) =>
      id == 3 && kind == sofab.ArrayKind.unsigned ? 8 : null;   // count: 8
  @override
  int? onFixlenLenBound(int id, int subtype) =>
      id == 1 && subtype == sofab.FixlenType.blob ? 64 : null;  // maxlen: 64
  ```

  For a field that answers, the declared bound *replaces* the cap: a wire
  count/length past it is `invalid` (decided at the count/length word, before
  the payload), and one within it decodes however tight the cap is.
  `kind`/`subtype` are what the **wire** declares — return `null` for one the
  field does not declare, since that is a skipped field and no schema bound
  covers it. Both hooks are asked at most once per field and only once a cap has
  actually been exceeded. `onFixlenHeader`/`onArrayBegin` fire *before* the cap
  is weighed either way, so a consumer that enforces its bound there always sees
  the header.

## Build & test

```console
dart pub get
dart analyze --fatal-infos      # build: no errors
dart test                       # runs the shared vectors + streaming/malformed/truncation
dart run example/person.dart    # the generated-object demo
bash bench/run_bench.sh         # release build: `dart compile exe` (AOT) + run
```

The test suite reads the shared conformance vectors from
[`assets/test_vectors.json`](assets/test_vectors.json) (copied verbatim from
`corelib-c-cpp`) and runs encode, decode, chunked-encode, chunked-decode,
skip-ids, roundtrip, malformed-input, truncation and invalid-UTF-8 checks. CI
enforces a >90% line-coverage bar.

Both configurations are built: `dart run` / `dart test` are the debug (JIT)
configuration, and the release configuration is AOT — `dart compile exe`, which
CI runs on `example/person.dart`. Compiled output lands in `build/`, which is
git-ignored.

## Benchmarks

Three tools, following the cross-language [`BENCH_SPEC.md`](https://github.com/sofa-buffers/documentation/blob/main/BENCH_SPEC.md):

```console
bash  bench/run_bench.sh          # AOT-native throughput + per-op (recommended)
bash  bench/run_callgrind.sh      # Callgrind Ir/op (instructions retired per op)

# Quick JIT variants (no compile step, but slower / with VM warmup):
dart run bench/bench.dart         # throughput (MB/s) over a ~1s CPU-time loop
dart run bench/perf.dart          # per-op cost for the 170-byte perf message

# Allocations per op (JIT only — it needs the VM service):
dart run bench/alloc_profile.dart
```

> **Run the benchmarks AOT-compiled** (`bench/run_bench.sh` uses
> `dart compile exe`) for representative numbers: it removes JIT warmup and is
> the fair comparison to the compiled ports (C/C++/Rust/Go), which also run
> native. `run_callgrind.sh` already builds an AOT target.

- **`bench`** — practical throughput on *this* machine, in MB/s, for encode and
  decode of BENCH_SPEC's four datasets: `u64 array (1000)`, the small `typical`
  message, an unbounded 1 MB `blob`, and `composite` (wrapper array, multi-byte
  UTF-8, depth-3 nesting, an omitted default, a two-byte field header). Two rows
  need reading with care:
  - the **`blob 1MB`** rows are bandwidth-bound — five bytes of that message are
    metadata and a million are payload — so their MB/s is this machine's
    `memcpy`. What they are for is the *gap* between `one-shot` (one contiguous
    write into a caller buffer, no sink) and `streaming` (the same bytes through
    ~245 flushes of a 4096-byte buffer), and that gap is legible as
    instructions, not as MB/s — read it in `run_callgrind.sh`. There is no
    `blob 1MB passthrough` row: this port implements no pass-through, so every
    `string`/`blob` run goes through the output buffer.
  - **`decode: composite skip-all`** refuses every field at header time
    (`shouldRead` → `false`, `onSequenceStart` → `null`). Its distance from
    `decode: composite` is what not-decoding is worth.
- **`perf`** — per-op cost of serialize/deserialize. The Dart VM exposes no
  hardware cycle counter, so `cycles/op` is reported as unavailable and CPU
  time/op is the machine-neutral signal. That time comes from libc's `clock()`
  through `dart:ffi` — process CPU time at microsecond resolution, the same
  clock the C and C++ ports use.
- **`run_callgrind.sh`** — instructions-per-op under Callgrind: deterministic
  and machine-independent. It uses the **two-rep subtraction** method (Dart has
  no stable per-workload native symbol to toggle), running an AOT-compiled
  target at two rep counts and subtracting to cancel startup and setup cost.
- **`alloc_profile`** — allocations and allocated bytes per op, from the VM
  service's per-class accumulators, for encode and decode of every payload shape
  at 16 bytes and at 4096. It runs the workload in a spawned isolate (the
  service RPC allocates in the isolate it reports on) and reports every row net
  of a `noop` row measured the same way. What it is for is the property the
  memory rule protects: a row must not cost more because the payload in it is
  larger. `test/alloc_profile_test.dart` asserts exactly that, so it is a gate
  rather than a report.
