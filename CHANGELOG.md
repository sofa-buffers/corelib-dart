# Changelog

## Unreleased

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
