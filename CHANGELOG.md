# Changelog

## Unreleased

### Changed — the generated-object example speaks the closed name set (§6.1.1)

`example/person.dart` is this port's only description of the generated-object
layer, and the README's *Generator* section quotes it — so its spellings are
what a Dart user learns. They were outside §6.1.1's closed set, including the
one it names as forbidden: `serializeTo` beside `serialize` is exactly the
"second name for either" a port MUST NOT add.

* `encodeInto(Encoder)` → **`serialize(Encoder)`** — the streaming-out half that
  talks to the corelib.
* one-shot `serialize()` → **`encode()`**; static `deserialize(bytes)` →
  **`decode(bytes)`** — the convenience pair, a thin wrapper over the streaming
  one.
* `serializeTo(sink, {bufferSize})` is **gone**. Streaming out is the §5.1
  pattern it was hiding: build an `Encoder` over the buffer you own, hand it your
  sink, call `person.serialize(enc)`, `enc.flush()`. That also removes the
  `bufferSize:` shortcut, the last place the example allocated on the caller's
  behalf.
* `Person.deserialize()` is new: the per-field hook the corelib's decoder calls
  (a visitor bound to the instance, §5.2), which `Person.decoder()` packages for
  the common case.

Example only — the corelib's own API (`feed`, `write*`, `read*`,
`beginSequenceLazy`, …) is §6 API and keeps its names. `test/generated_surface_test.dart`
pins both halves: it compiles against the six §6.1.1 names, and it reads
`example/person.dart` and `README.md` back, rejecting any declared member or
documented call outside the set. Closes #42.

### Changed (breaking) — the encoder's output buffer is always caller-supplied (§5.1)

`Encoder`'s streaming constructor allocated a `Uint8List(bufferSize)` whenever
`buffer:` was omitted, which was its default shape. §5.1 is explicit that a
corelib "**MUST NOT** allocate an output buffer. Every buffer the encoder writes
into is caller-supplied. There is one buffer-ownership model rather than two" —
and the `bufferSize` knob was the second one, kept alive across the constructor,
`encodeToBytes` and the example's chunked helper (since removed — see the
§6.1.1 entry above).

* `Encoder(sink, {required Uint8List buffer, int offset = 0})` — `buffer` is now
  **required** and `bufferSize` is gone. `Encoder(sink, bufferSize: n)` becomes
  `Encoder(sink, buffer: Uint8List(n))`: the same allocation, in the layer §5.1
  puts it in. `Encoder.overBuffer` is unchanged.
* `Encoder.encodeToBytes` keeps its `bufferSize:` and stays the §6.1 one-shot
  convenience, but it is now the caller: it allocates its scratch buffer once,
  visibly, then drives an ordinary encoder over it. That is the package's only
  output-buffer allocation site, and it sits above the corelib's write path —
  the unbounded shape of §5.1's generated-layer rule ("the generated-object
  layer allocates; the corelib does not").
* `example/person.dart` allocates in its own streaming-out path and documents
  why the allocation belongs there; the README's memory-handling table no longer
  offers "or the encoder allocates a default".

No wire change, and no behaviour change for callers that already supplied a
buffer. `test/buffer_ownership_test.dart` pins the rule: no encoder constructor
takes a size to allocate from, one cannot be constructed without handing a
buffer over, and every flushed chunk is a window onto the caller's storage —
never grown, never replaced. Closes #41.

### Fixed — a receiver limit no longer overrides a schema bound (§6.2.1, §6.3)

`DecoderLimits` was applied to **every** materialized field, and applied
*before* the hooks through which a schema-bound consumer states its own bound.
Both halves are wrong. §6.2.1: a `max_dyn_*` limit is deployment configuration
protecting the receiver from a field the schema leaves *unbounded*, and it "MUST
NOT be applied to a field the schema already bounds. There the schema bound
governs and its violation is `INVALID`". §6.3 says the same from the other end —
`LimitExceeded` is "never raised for a field the schema bounds". So a deployment
cap of 4 turned a `blob<maxlen 64>` carrying 100 bytes into `limitExceeded`
where §7.1 requires `invalid`, rejected a perfectly valid 32-byte value of that
same field, and the consumer never even learned of the header.

Two changes, both at the header word, both still ahead of the allocation the
limit exists to prevent:

* **Order.** `onFixlenHeader` / `onArrayBegin` now fire *before* the limit is
  weighed, so a schema-bound consumer sees the breach it is supposed to judge.
  For a fixlen array that moves the limit behind the `fixlen_word` — deciding
  whether the schema bounds the count is a question about the element kind
  (§7.3) — where it lands before the payload allocation just the same.
* **Exemption.** Two new hooks say which fields the schema bounds:

  ```dart
  int? onArrayCountBound(int id, ArrayKind kind) => null; // schema `count:`
  int? onFixlenLenBound(int id, int subtype) => null;     // schema `maxlen:`
  ```

  Answering swaps the rule for that field: the configured limit stops applying
  and the returned bound decides instead, with a wire count/length past it
  reported as `invalid` — the outcome §7.1 wants — at the count/length word. As
  everywhere else, `kind`/`subtype` are what the *wire* declares, so returning
  `null` for a kind the field does not declare keeps the receiver limit on a
  §7.3 skip, which no schema bound covers.

Both are asked at most once per field and only just after a configured limit has
already been exceeded — the only place the answer changes an outcome — so a
decode with no `DecoderLimits` set pays nothing for them, and a visitor that
does not override them decodes exactly as before. `DecoderLimits` is documented
as the unbounded-field backstop it is; `test/schema_bound_limit_test.dart`
covers both surfaces with an unbounded control one byte from every bounded case.
Closes #40.

### Added — `minOutputBuffer`, declared and enforced at buffer handover (§5.1)

`sofab.minOutputBuffer` is the port's **`MIN_OUTPUT_BUFFER`**: the smallest
buffer this library accepts *for streaming*. Its value is **1** — the encoder
splits every atomic unit (field header, `fixlen_word`, `element_count`, a scalar
or array-element varint, an `fp32`/`fp64` element) across a flush and reserves
nothing contiguously, which is the case §5.1 gives the floor of `1`. A one-byte
streaming buffer produces output byte-identical to the one-shot path.

The constant was previously nowhere: not declared, not exported, not documented,
and — the part with teeth — not enforced. §5.1 binds it to a buffer installed
**with a flush sink**, at construction and at every mid-stream buffer-set, where
`buflen - offset >= MIN_OUTPUT_BUFFER` must hold and a shortfall is rejected
*where the buffer is handed over*. Without that check a degenerate handover was
accepted and silently corrupted the caller's reservation instead: an encoder
built over `Uint8List(4)` with `offset: 4` — zero room — took the buffer, and the
first flush rebased the cursor to 0 and wrote the message straight through the
four bytes the caller had reserved for its framing header.

`Encoder(...)` and `installBuffer(...)` now validate the handover and throw
`SofabException(invalidArgument, …)` — the same mechanism as an out-of-range
`offset`, which `installBuffer` now checks too — before any byte is written, so a
rejected installation leaves the encoder writing into the buffer it already had.
A buffer installed **without** a sink (`Encoder.overBuffer`) keeps its exemption:
no flush can occur, no atomic unit can be split, so a two-byte message still
encodes into a two-byte buffer.

Note for callers handing over a zero-length buffer together with a sink: that
installation now fails with `invalidArgument` where it is made, instead of with
`bufferFull` at the first write. No wire-format or hot-path change — the check
runs once per handover. `test/min_output_buffer_test.dart` covers the §7.2
item-4 pair (encode at exactly the minimum, incl. a `blob`/`string` run longer
than the buffer; one byte short rejected at handover; and the sink-less
converse), the shared-vector chunked-encode test now uses `minOutputBuffer` as
its first buffer size, and the README's memory section states the value.

### Added — a caller-supplied output buffer without a flush sink (§5.1)

`Encoder.overBuffer(buffer, {offset})` installs a caller-owned buffer with **no**
sink — the first of §5.1's required capabilities — and `Encoder.written` returns
the bytes of the active installation as a zero-copy view: the whole message, for
a sink-less encoder that had room for it.

Before this the only constructor took the flush callback as a required
positional argument, so "here is my buffer, tell me if it is too small" could not
be expressed at all. A caller with nothing to flush to had to pass a no-op sink,
and that produced the exact behaviour §5.1 forbids: `_drain` handed the bytes to
the callback and rewound the cursor, so everything past the end of the buffer was
**silently discarded** and the encode returned as if it had succeeded — a 4-byte
buffer swallowed a 10-byte varint without a word.

`_drain` now returns without touching the cursor when there is no sink, so the
buffer stays full and the write that does not fit throws `BufferFull`: no partial
output dressed up as complete. `flush()` on such an encoder is a no-op that
leaves the message in the caller's buffer, and `installBuffer` / `reset()` work
in this mode too. No minimum binds a sink-less buffer — a minimum is a streaming
precondition and nothing streams here — so a two-byte message encodes into a
two-byte buffer, which is what keeps a buffer sized from a generated `MAX_SIZE`
exact.

No wire-format or hot-path change: the sink-installed path is untouched apart
from one null test in the cold drain. Every shared vector is now also encoded
sink-less into an exactly-sized buffer and asserted byte-identical, with the
one-byte-short buffer asserted to report `BufferFull` (the converse half of §7.2
item 4); the sink-less handover cases live in `test/buffer_install_test.dart`,
and the README documents the mode and its memory behaviour.

### Fixed — a buffer installed from inside the flush callback keeps its start offset (§5.1)

`_drain` rewound the cursor **after** invoking the sink, so an
`installBuffer(buf, offset: n)` call made from inside that callback had its
offset immediately overwritten with 0. Only the constructor's installation kept
its offset: every later packet started at byte 0 of the freshly installed buffer
and wrote over the framing-header room the caller had just reserved. A
take-and-replace sink re-arming 4 bytes per packet over a 24-byte buffer
produced packets of 20, 24, 24, … bytes — the 24-byte ones having clobbered
their own header room.

The cursor is now rewound **before** the sink runs. That leaves 0 as the
copying-sink default (a callback that returns without installing anything has
copied the bytes, so the active buffer stays active and is refilled from its
start) while letting `installBuffer` have the last word — §5.1 exactly: *the
start offset belongs to the installation, not to the buffer*. A bare return
resumes at 0, a buffer-set resumes at that call's offset, and passing the
**same** buffer back re-arms the reservation like any other installation.

No API, wire-format or performance change: the encoded bytes were always
correct, only the caller's reserved prefix was not. The §7.2 item-4 handover
cases — taking sink, copying sink, same-buffer re-installation, reserved-prefix
integrity — now live in `test/buffer_install_test.dart`, and the README's
streaming section documents both halves of the returning-callback contract.

### Fixed — a one-shot integer array no longer sizes its result from the wire count (§5.2, §6.2.1, §7.2)

`Decoder.decode` allocated the whole `Int64List` from the array's
`element_count` before reading a single element. With no receiver limit
configured, a **6-byte** message declaring a legal-under-`ARRAY_MAX` count of
2^31−1 (`03 ff ff ff ff 07`) asked the VM for 17 GB and died with
`OutOfMemoryError` — a crash where §7.2 item 5 requires a well-defined outcome,
and an allocation where §6.2.1 puts the decision *before* it.

On the one-shot surface the entire message is already in hand and every element
costs at least one varint byte, so a count above the bytes that remain is
refuted by the input itself. The result is now sized from what those bytes can
hold, capping the allocation at the order of the message; the array still
decodes over the prefix, so an element outside its declared width
(`onArrayElemBound`) keeps outranking the truncation (§5.2) rather than being
lost to an early bail-out, and the outcome is `INCOMPLETE`. No API, wire-format
or performance change: a count the input can satisfy takes exactly the path it
always did.

The streaming surface is unchanged by design — a chunked decoder cannot know how
many bytes still follow, and `DecoderLimits(maxArrayCount: …)` is §6.2.1's
instrument there. Regression cases live in `test/truncation_test.dart`, with the
INVALID-over-INCOMPLETE ordering pinned in `test/elem_bound_test.dart`.

### Fixed — `ARRAY_MAX` is an unsigned ceiling (§6.2, §4.8)

An array `element_count` with **bit 63 set** slipped past the format ceiling.
The count word is a full u64 on the wire and the varint readers accept the whole
range, but Dart has no unsigned compare: `count > arrayMax` on a value ≥ 2^63
tests a *negative* `int` and is false. What followed depended on the path — a
materializing decode threw an uncaught `RangeError` out of `decode`/`feed`
(`Int64List(count)` / `Float32List(count)`), while a skipping decode ran its
element loop zero times and reported `COMPLETE` for a bogus **empty array**.
`count * length` wrapped for the fixlen shape, moving the read cursor backwards.

All four count guards — both array wire types, on both decode surfaces — now
test the sign bit first (`count < 0 || count > arrayMax`), before any
allocation, any multiplication and any cursor move, so such a count is the
`INVALID` outcome §7.2 item 5 requires and never a crash. No API, wire-format or
performance change: a legal count (≤ `ARRAY_MAX`) takes exactly the path it
always did. Regression cases for both array wire types × 2^63 / 2^64−1 /
`ARRAY_MAX`+1 × read and skip × one-shot, chunked and byte-at-a-time live in
`test/malformed_test.dart`.

### Added — `onArrayElemBound`: an integer array's declared element width (§7.1)

`MessageVisitor.onArrayElemBound(id, kind)` answers with an `ElemRange`, or
`null` where the field declares no width narrower than the 64-bit value domain.
It is asked **once per array field**, at the count word, and the decoder then
applies the range as the elements go past.

It exists because the whole-array callbacks cannot answer in time. A declared
element width is a validity bound (MESSAGE_SPEC §7.1) and §5.2 makes INVALID
dominate INCOMPLETE, so an element already outside its width keeps the message
INVALID however little follows it — but a guard over the assembled
`onSignedArray`/`onUnsignedArray` list only runs for an array that *arrives*,
and the array in question is precisely one that does not:

```
arrays.i8 (count 5), first element 5208, message ends there
a6 06 0c 05 b0 51   ->  INCOMPLETE, the 5208 never looked at
```

Same shape as `onArrayBegin` one level down — only the decoder sees the element
in time, only the schema knows the bound — and the same §7.3 rule applies:
`kind` is what the *wire* declares, and an implementation returns `null` for a
kind it does not declare, because an array whose element kind contradicts the
schema is a skipped field whose elements were never this field's value.

The bound decides **every** array of that field, not only a truncated one: an
element outside its declared width is INVALID wherever it sits, and the
whole-array callbacks return `void`, so a visitor that answered the hook has no
channel left to reject through. Both decode surfaces apply it — the streaming
one at the element, two integer compares with no call; the contiguous one in a
single sweep once the array has arrived (and over the decoded prefix when it
does not), which keeps its word-wise element loop a pure decode and costs
nothing at all for a field that declares no narrowed width.

Additive: a visitor that does not override it decodes exactly as before. Found
by Crucible F-0043; the generator half is sofa-buffers/generator#267.

### Performance — word-wise varints, and typed-data views only where they pay

No API, wire-format or conformance change: every shared vector still produces
byte-identical output, and both decode surfaces still agree on every status.
Instruction cost (Callgrind `Ir/op`, the machine-independent measure of §10):

| Workload | before | after | |
|---|---:|---:|---:|
| encode: u64 array (1000) | 274,696 | 95,214 | **2.89×** |
| decode: u64 array (1000) | 290,847 | 101,520 | **2.86×** |
| encode: typical message | 1,780 | 1,041 | **1.71×** |
| decode: typical message | 2,707 | 2,078 | **1.30×** |

The measurements behind these changes are Dart-AOT-specific and mostly
counter-intuitive: a bounds-checked `Uint8List` byte access costs ~15
instructions, a `ByteData.setUint64` ~2.5 per byte, and **constructing any
typed-data view costs 174–311** — more than decoding a whole small message.
`int.bitLength` is a real call, not a count-leading-zeros intrinsic. Int64
boxing, by contrast, is *not* a factor: large values cost the same per byte as
small ones, and a hi/lo Smi split measured slower.

- **Changed** varint encoding and decoding to work a 64-bit word at a time.
  The encoder scatters eight 7-bit groups into a register and stores them with a
  single `setUint64`; the decoder loads eight bytes and locates the terminating
  byte with `~x & 0x8080808080808080`. Both the scatter and the gather are three
  log-steps rather than eight mask-shift-or terms (12 operations instead of 23).
- **Changed** the decoder to build its wide `ByteData` view **lazily**, and only
  in array element loops where it amortizes over many elements. Scalar varints
  read byte-at-a-time and one-off `fp32`/`fp64` payloads stage through a shared
  8-byte scratch, so a message carrying neither an array nor a float never
  constructs a view at all. Fixed per-decode overhead: 316 → 121 instructions.
- **Changed** integer scalar writes to emit the field header and its value under
  a **single** buffer-capacity check (a header plus a value is at most 20 bytes),
  roughly halving per-field encode cost.
- **Changed** the default `MessageVisitor.onStringBytes` to settle validity and
  transcoding in one pass for ASCII payloads, skipping both the general UTF-8
  validator and `utf8.decode`. Non-ASCII payloads are validated exactly as
  before — still strict, still never lossy (§6.4).
- **Changed** `Decoder.feed` to take a `Uint8List` fast path, so streaming input
  no longer pays an interface call per byte.
- **Added** `test/varint_test.dart`. The rewritten paths had no coverage of the
  §4.1 rule that a decoder **MUST accept** a non-minimal varint and normalize it
  on re-encode, so a regression there would have passed the whole suite silently.
  It pins every varint byte-length boundary (1..10), the non-minimal-accept rule,
  the 64-bit bound being a property of the *encoding* (an eleventh byte is
  `invalid` even when it contributes nothing), and arrays split across the
  word/tail boundary — each asserted on **both** the one-shot and the streaming
  decoder.

## 0.10.0 - 2026-08-01

### Breaking — `onArrayBegin` carries the element kind, and waits for it (§4.8)

Crucible finding **F-0042** (issue #23). A fixlen array carries two words —
`element_count`, then the `fixlen_word` — and CORELIB_PLAN §4.8 fixes the order in
which they are acted on: the element **subtype** decides whether the field is this
schema field's value at all (MESSAGE_SPEC §7.3), and only a field that survives
that gets the schema `count` bound. The old hook fired between the two words and
carried no kind, so generated code could not implement that order at all.

- **Added** `sofab.ArrayKind` — `unsigned`, `signed`, `fp32`, `fp64`. The two
  fixlen kinds are deliberately kept apart; the ordinals (0/1/2/3) are normative
  and identical across every SofaBuffers port.
- **Changed** `MessageVisitor.onArrayBegin(int id, int count)` →
  `onArrayBegin(int id, ArrayKind kind, int count)`. Any override must be updated;
  generated code is the expected consumer and sofabgen changes in lockstep.
- **Changed** where the hook fires for wire type `arrayFixlen`: now **after** the
  `fixlen_word` has been read and validated, so `kind` is the real element
  subtype. Consequences, both intended: a message that ends *between* the two
  words is `incomplete` rather than being judged on the count alone, and a header
  whose kind contradicts the declared element type reaches the consumer as a
  skippable field with no bound applied to its count.
- **Unchanged**: the `ARRAY_MAX` format ceiling and the `maxArrayCount` receiver
  policy limit both still fire on the *count* word (the latter still as
  `limitExceeded`); an illegal fixlen-array element subtype (string/blob) or a
  width mismatch is still `invalid`, never a §7.3 skip; integer arrays still fire
  the hook immediately after their count word; a zero-count fixlen array still
  fires the hook exactly once, with the correct kind. The hook still fires once
  per array field, never per element.

### Fixed — a skipped `string` is no longer UTF-8-validated (CORELIB_PLAN §6.4)

Crucible finding **F-0038** (#22). UTF-8 validation now fires only where a
`string` is **materialized** — read into a declared destination — never on a
payload the consumer is skipping, whether it is skipped because the field id is
unknown to the schema (§6.4) or because the header's wire type/subtype
contradicts it (MESSAGE_SPEC §7.3, which routes to the same skip).

- **Added** `MessageVisitor.onStringBytes(int id, Uint8List bytes)` — the
  decoder's string path. It delivers the **raw wire bytes**, un-validated and
  un-transcoded, and fires only for a field being materialized. A Dart `String`
  cannot carry invalid bytes without the lossy U+FFFD substitution §6.4 forbids,
  so handing the bytes over is the only way a push consumer can resolve its
  destination *before* deciding to validate. Schema-bound (generated) consumers
  override it, switch on `id` first, and call `utf8Valid` + `utf8.decode` only
  inside a matched arm.
- **Not breaking.** The default `onStringBytes` keeps this port's always-strict
  behaviour for hand-written visitors: it validates, fails the decode with
  `invalid` on malformed bytes, and forwards the decoded value to `onString`.
  Existing visitors are unaffected; `onString` is now documented as a
  convenience layered on `onStringBytes` rather than the decoder's own path.
- Unchanged: framing is still fully validated while skipping (the F-0012 half) —
  the field header, the `fixlen_word`, reserved subtypes 0x4–0x7,
  `FIXLEN_MAX`/`ARRAY_MAX`, `MAX_DEPTH`, varint overflow, and the exact
  `length`-byte advance. Also unchanged: the strict encode side, `blob` (never
  UTF-8-validated), and the `utf8Valid` validator itself.

### Breaking — sequence framing is now lazy (MESSAGE_SPEC §2, CORELIB_PLAN §6)

Depends on the spec change in `sofa-buffers/documentation#29`.

- **Removed** `Encoder.beginSequence` (the eager begin). It has no remaining
  caller: a sequence that gets content is opened lazily and produces the same
  bytes, and a contentless one is either dropped or forced.
- **Added** `Encoder.beginSequenceLazy(id)` — opens a scope and holds the header
  back; any field write emits the whole pending run, outermost header first.
- `Encoder.endSequence()` now **drops** a sequence whose header is still
  pending — header and end marker both — so a sequence-typed field equal to its
  declared default is omitted instead of being framed empty, and an all-default
  message encodes to zero bytes.
- **Added** `Encoder.endSequenceKeep()` — behaves like a write: commits the
  pending run *and* writes the end marker, so a contentless sequence still
  reaches the wire as `begin` + `end`. Required for a wrapper-array **element**,
  whose presence carries the array's length (MESSAGE_SPEC §5.1), and for an
  explicitly empty array whose declared default is non-empty.
- The hold-back is **unbounded**: the encoder's pending run grows on demand and
  reaches the full `MAX_DEPTH` (255), so the output is canonical at every
  nesting level (CORELIB_PLAN §6, "How deep the hold-back reaches" — bounding
  the run and framing eagerly past the bound is an allowance for heap-free
  profiles, which Dart is not). It is allocated on the **first** held-back
  header, so an encoder that never opens a sequence pays nothing for it. No
  `lazySeqDepth` constant is exported.
- Shared `assets/test_vectors.json` re-synced from `corelib-c-cpp`: four vectors
  changed their `serialized_sparse` bytes (`empty_sequence`,
  `nested_empty_sequences`, `empty_sequence_between_fields`,
  `array_string_all_default`); every dense `serialized` hex is unchanged — which
  is why this port's vector suite is unaffected. It asserts `serialized` only:
  `serialized_sparse` is the message-layer form, produced and checked by the
  **generator's** conformance drivers, not by a corelib.

## 1.0.0

Initial release of `corelib-dart`, the high-speed Dart core library for
SofaBuffers.

- Full streaming `Encoder` (fixed buffer + flush callback, mid-stream buffer
  swap, start offset, reusable via `reset()`).
- Full streaming `Decoder` (push-feed / pull-read visitor, byte-resumable state
  machine, three-valued `COMPLETE` / `INCOMPLETE` / `INVALID` outcome plus a
  distinct `limitExceeded`, auto-skip of unread fields and sub-sequences).
- All eight wire types: unsigned, signed (zig-zag), fixlen (fp32/fp64/string/
  blob), unsigned/signed/fixlen arrays, and sequences.
- Always-strict UTF-8 (Dart is a Unicode-string target): `utf8Valid` primitive
  and a strict, never-lossy string encoder; invalid UTF-8 rejected symmetrically.
- Receiver-side technical limits (`DecoderLimits`) surfaced as `limitExceeded`,
  distinct from `INVALID`.
- Validated against the shared conformance vectors (encode, decode, chunked,
  skip, roundtrip) plus malformed-input, truncation and invalid-UTF-8 suites.
- `perf`, `bench` and `run_callgrind.sh` benchmark tools per `BENCH_SPEC.md`.
- Generated-object example (`example/person.dart`).
