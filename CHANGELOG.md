# Changelog

## Unreleased

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
