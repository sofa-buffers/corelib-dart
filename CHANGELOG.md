# Changelog

## Unreleased

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
- **Added** the `lazySeqDepth` constant (32): the hold-back window. A run nested
  deeper is framed eagerly — valid, merely non-canonical.
- Shared `assets/test_vectors.json` re-synced from `corelib-c-cpp`: four vectors
  changed their `serialized_sparse` bytes; every dense `serialized` hex is
  unchanged.

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
