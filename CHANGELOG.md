# Changelog

## Unreleased

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

Additive: a visitor that does not override it decodes exactly as before. The
contiguous path pays nothing for it — it walks the decoded prefix only when the
array fails, leaving the word-wise element loop a pure decode — and the
streaming path checks at the element, two integer compares with no call. Found
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
