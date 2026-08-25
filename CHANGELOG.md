# Changelog

## Unreleased

### Conformance with CORELIB_PLAN@c837108 — the codec allocates no payload storage

**Breaking for a visitor that overrode nothing but relied on where its values
came from; source-compatible for everything else.** `onString`,
`onStringBytes`, `onBlob` and the four whole-array callbacks keep their
signatures and keep firing.

* **Every decoded payload lands in a destination the caller supplies.** Four new
  `MessageVisitor` hooks — `onBytesDest` / `onBytesDone` for a `string`/`blob`,
  `onArrayDest` / `onArrayDone` for an array — are asked at the header that
  announces the size, before a payload byte is consumed (§6.6.3). Their defaults
  allocate one exactly-sized destination and forward it to the callbacks above,
  so a hand-written visitor is unchanged; a consumer that owns its storage
  overrides the two `…Dest` hooks and the codec allocates nothing at all.
  Returning `null` declines the field, which is then walked like a skipped one;
  returning something shorter than announced, or of the wrong element type, is
  `SofabError.invalidArgument` (§6.3's third refusal tier).
* **`Decoder.decode` no longer hands out a view onto the caller's buffer.**
  §6.7.1 gives the one-shot path no view exemption — "decode(buffer) copies
  too" — so both surfaces now copy into the caller's destination. Code that
  retained an `onBlob`/`onStringBytes` value and read it after mutating the
  input buffer saw the mutation; it no longer does.
* **The receiver caps are finite and mandatory.** `DecoderLimits`' three fields
  are non-nullable with the defaults `defaultMaxDynArrayCount` (2²⁰),
  `defaultMaxDynStringLen` (16 MiB) and `defaultMaxDynBlobLen` (64 MiB): §6.2.1
  admits "no unset state and no unlimited mode". Passing `null` no longer
  compiles, and a negative value is rejected. A decode that legitimately exceeds
  a default now needs the cap raised — before this, seven bytes could ask the VM
  for 17 GB.
* **A wrapper array's element index is bounded too**, by a new `rcap` argument
  on every collector in `seq.dart`, and `MessageVisitor.limitExceeded()` is the
  channel it reports through — the receiver-cap counterpart of `invalidate()`,
  arriving as `DecodeStatus.limitExceeded` rather than as INVALID, which §6.2.1
  forbids for a policy bound (closes #86).
* **The encoder transcodes a string into the output buffer** instead of into a
  buffer of its own, and its held-back sequence run and the decoder's parse
  stack are sized in the constructor rather than grown.
* `utf8LengthStrict` / `utf8LengthStrictUnits` join the UTF-8 primitives: the
  byte length of a `String`, or −1 where an unpaired surrogate makes it
  unencodable.
* New: `bench/alloc_profile.dart` measures the codec's allocations per op and
  `test/alloc_profile_test.dart` gates them; the shared `sequence_growth`
  vectors run.

### The generated layer's schema-free half, moved here (VisitorBase, decodeUtf8Strict, utf8Length, elementsEqual)

Purely additive: nothing existing changed name or behaviour, and generated code
in the wild — which carries its own copies of all four — keeps compiling.

Every file `sofabgen` emits for Dart opens with ~96 lines that have no schema in
them: a visitor base, a UTF-8 materializer, a UTF-8 byte-length counter, a list
comparison. Their code is the same for every message; only the arguments differ.
That makes them corelib code by the rule the generator adopted in its
ARCHITECTURE §8 (sofa-buffers/generator#345) — a helper whose schema dependence
is carried entirely by arguments and type parameters belongs where the concept
already lives, written once, instead of being re-emitted into every user's
source tree along with the comment explaining it.

* **`VisitorBase`** — a `MessageVisitor` whose `onStringBytes` and
  `onSequenceStart` defaults are the ones a schema-bound consumer needs: an id
  the scope does not declare is *skipped*, not inspected, and a sub-sequence it
  does not bind is skipped whole, children included. `MessageVisitor`'s own
  defaults (validate the string, descend the sequence) are right for a
  hand-written visitor and wrong for a generated one — MESSAGE_SPEC §7.3 makes
  an undeclared id a skipped field, and CORELIB_PLAN §6.4 never validates those.
  This class is what `MessageVisitor.onStringBytes`' documentation has been
  prescribing in prose since strict UTF-8 landed; now it can be extended.
* **`decodeUtf8Strict(Uint8List) → String?`** — the decode-side twin of
  `encodeUtf8Strict`: valid UTF-8 in, `String` out, `null` for anything
  malformed, never a U+FFFD substitution. It replaces the `utf8Valid(bytes)` +
  `utf8.decode(bytes)` pair the docs used to prescribe, which walks the payload
  twice; this validates from the **first non-ASCII byte** only, and settles an
  all-ASCII payload in a single scan through `String.fromCharCodes`. The default
  `onStringBytes` now calls it rather than keeping a second copy of the same
  scan, so both string paths are one implementation.
* **`utf8Length(String) → int`** — the exact UTF-8 byte length that sizes a
  `fixlen_word`, without allocating the transcode buffer to find it out. Walks
  code units rather than runes, so a surrogate pair costs no `RuneIterator`.
* **`elementsEqual<T>(List<T>, List<T>) → bool`** — pairwise list comparison,
  which is how a generated encoder decides whether a list field still equals its
  declared default (MESSAGE_SPEC §5.1). Dart's `==` on two `List`s is identity,
  so a freshly built list never equals its default without it.

The collectors of the same block (`_StrSeq` / `_BlobSeq`) are deliberately not
here yet: they report a rejected element through a sticky INVALID flag they take
in their constructor, and the visitor callbacks return `void`, so moving them
needs an INVALID channel on `MessageVisitor` first (#64).

**Tests.** `test/generated_support_test.dart`, 19 cases. None of this is
wire-visible — a port could validate a skipped string, or omit a field holding a
`NaN`, and still emit byte-identical output — so the shared vectors cannot reach
any of it and CORELIB_PLAN §7 makes unit tests the only cover. Pinned: an
invalid-UTF-8 string at an undeclared id decodes to COMPLETE under `VisitorBase`
and to INVALID under a plain `MessageVisitor` (the exact boundary the generated
original guarded); an override that binds one id falls through to the skip for
the rest; a skipped sequence takes its grandchildren with it; `decodeUtf8Strict`
agrees with `utf8Valid` on every malformed shape, including one hidden behind an
ASCII prefix; `utf8Length` equals `encodeUtf8Strict(s).length` across the 1/2/3/4-byte
boundaries and measures an unpaired surrogate the encoder refuses; and
`elementsEqual` on the two IEEE-754 cases that decide whether a field is written
(`NaN` never equal, `-0.0 == 0.0`).

### Benchmarks — the BENCH_SPEC datasets this port was missing, and a clock that can measure them

No library change: `lib/` is untouched. This is the `bench/` half of the spec.

**The clock first, because it invalidated everything else.** `CpuClock` read
`utime`+`stime` out of `/proc/self/stat`, which counts in `USER_HZ` ticks —
10 ms. Both tools size their timing batch by growing it until it spans 10 ms, so
a batch of work lasting a microsecond that happened to straddle a tick boundary
"measured" a full 10 ms and the batch stopped growing there; the measurement
loop then spent its second reading `/proc` instead of running the workload.
Single rows came out wrong by more than an order of magnitude, and differently
on each run — `decode: typical message` printed 8.58 MB/s on one run of `main`
and 158 MB/s on the next. It now reads libc's `clock()` through `dart:ffi`:
process CPU time at microsecond resolution, the clock BENCH_SPEC names and the
C and C++ ports use. `/proc/self/stat` remains as a fallback, wall-clock behind
it. `dart:ffi` is used by `bench/` only — the package still has no runtime
dependency, and `lib/` still imports nothing but `dart:core`/`dart:typed_data`.

**New datasets.** `bench` grows from 4 rows to 10, the full required set:

* **`blob 1MB`** — one unbounded `blob` field, 1,000,000 payload bytes,
  encoding to 1,000,005. Three rows: `one-shot` (a caller buffer sized by hand
  to the message, **no sink**), `streaming` (a 4096-byte caller buffer with a
  flush sink, ~245 flushes, pass-through not granted), and a decode fed in
  4096-byte chunks. The optional `passthrough` row is omitted rather than
  stubbed: this port implements no pass-through.
* **`composite`** — the paths the three flat datasets never reach: a 64-element
  wrapper array (element ids straddling the one-byte header boundary), 320 UTF-8
  bytes over all four sequence widths, depth-3 nesting, a field equal to its
  declared default that the encoder must *not* write, and the suite's only
  two-byte field header. Rows for encode, decode, and `skip-all` — every field
  refused at header time, the path a router or filter runs.

`run_callgrind.sh` reports all ten, driving the `blob 1MB` rows at BENCH_SPEC's
small rep pair (R1 = 1, R2 = 3), since a megabyte per op under Callgrind is slow.
Row layout is now byte-identical to the reference ports (`%-26s %12.2f`).

**Two tests, because a benchmark that measures the wrong thing fails silently.**
`test/bench_workloads_test.dart` pins the encoded size of every dataset — 170,
1,000,005 and 956 are cross-port parity checks, as much a conformance property
as anything in `test_vectors.json` — and round-trips each through the surface
its row drives it with. `test/bench_grammar_test.dart` runs the tools and
matches their output against the harness's own regexes, so a table that has
drifted out of the comparison fails here rather than quietly disappearing from
it. `bench --smoke` (one op per row) exists to make that check cost a second.

### Tests — strict UTF-8 through the streaming decoder, at the boundaries the vectors cannot reach (§6.4)

No behaviour change; this closes a coverage gap in the shared conformance
vectors themselves.

Every `invalid_utf8` seed in `assets/test_vectors.json` is a message of at most
six bytes whose bad sequence sits at payload offset 0, and this repo only ever
fed them one-shot. That leaves untested the arrival shape where "validate what
is new" and "validate the payload" come apart: an invalid sequence that
**begins at a payload offset at or beyond everything fed so far**, so that every
byte the decoder has already consumed was valid UTF-8.

`test/invalid_utf8_chunked_test.dart` builds that shape for each seed — a
96-byte ASCII prefix, the seed's bad bytes (parsed out of the vector, not
restated), a valid multi-byte tail — and feeds it with the chunk cut exactly at
the bad sequence, then one byte at a time, then split at every byte of the
message. It also covers the skip twin (§6.4: a skipped string is a length jump,
never validated, however many feeds it spans), that `onStringBytes` fires once
with the whole reassembled payload whatever the chunk size, that a cut inside a
*valid* 2-/3-/4-byte sequence still transcodes exactly, and that the INVALID
verdict is terminal against later well-formed bytes. Confirmed non-vacuous by
mutation: validating only the first 96 payload bytes keeps the existing
`invalid_utf8` suite green and fails 34 of the new cases.

`test/fp32_snan_test.dart` gains the encode-side twin of its streaming case:
`writeFp32Bits` and `writeFp32Array` through 1-, 2-, 3-, 5- and 6-byte output
buffers, where the four raw bytes straddle a flush and take the scratch-buffer
path (§5.1 + §4.6). That was the last reachable unexecuted line in
`lib/src/encoder.dart`, which is now at 100%.

Line coverage 98.35% → 98.57%. The 13 remaining lines are unreachable by
design: the big-endian-host fallbacks in `_readFp32Array`/`_readFp64Array` and
`_onArrFixWord` (no platform Dart targets is big-endian), the defensive
`return _fail(invalid)` after four already-exhaustive switches, and the private
constructors of the `WireType`/`FixlenType` constant holders.

### Perf — the streaming decoder stops paying per byte for bytes it already has (§5.2)

`Decoder.feed` walked every chunk one byte at a time through the state machine,
whatever the chunk held. Decoding a message in one 9 kB chunk therefore cost
**8.9×** what decoding the same bytes through `Decoder.decode` cost, even though
both surfaces had the whole message in hand. The per-byte walk is what makes
suspend-and-resume at any boundary work; it is not what a chunk that already
carries whole fields needs.

`feed` now takes whatever a chunk holds whole, and only falls back to the
per-byte reader for a field that genuinely straddles a boundary:

* a **whole varint** is lifted straight out of the chunk instead of accumulated
  a byte at a time, so every header, count and scalar costs one read;
* a **run of integer array elements** is decoded 64 bits at a time by
  `_varintRun` — the *same* word-wise reader the one-shot path uses, now shared
  rather than written twice;
* an **opaque payload** is moved in one copy including its last byte, instead of
  stopping one byte short so the byte-wise reader could notice the completion;
  completion moved into one `_payloadComplete` both readers call.

Alongside, on the same paths:

* an `fp32`/`fp64` payload stages in a reusable per-decoder slot — no
  `Uint8List` and no `ByteData` view per float field (a typed-data view costs
  ~300 instructions under Dart AOT). Per decoder, not a shared static, so
  interleaved decoders cannot corrupt each other;
* an open sequence no longer allocates a frame object: the scope carried nothing
  but its visitor, so `_Frame` is deleted and the innermost visitor is held
  directly instead of re-read off the stack for every field;
* `feed` normalizes a non-`Uint8List` chunk once instead of running a second,
  duplicated per-byte loop for it;
* `writeString` writes a pure-ASCII string in **one** pass. Its wire length is
  the code-unit count, so the header can go out first and the code units be
  tested and stored together, instead of one pass to prove the string ASCII and
  a second to copy it — `codeUnitAt` is a real call under Dart AOT and was being
  made twice per character. The speculation is entered only with room for
  everything it could write, so a string that turns out not to be ASCII rewinds
  the cursor *and* the held-back sequence run and leaves no trace.

Measured with `bench/run_callgrind.sh` (Callgrind Ir/op, deterministic), plus
the two extra `dec_*_stream` workloads `bench/callgrind_target.dart` now
accepts:

| workload | before | after | |
|---|---:|---:|---|
| decode `u64 array (1000)`, streaming | 923 059 | 102 625 | **−88.9 %** (9.0×) |
| decode `typical`, streaming | 5 806 | 5 122 | −11.8 % |
| decode `u64 array (1000)`, one-shot | 105 525 | 102 064 | −3.3 % |
| decode `typical`, one-shot | 2 099 | 2 128 | +1.4 % |
| encode `typical` | 1 046 | 1 011 | −3.3 % |
| encode `u64 array (1000)` | 95 220 | 95 214 | — |

The one +1.4 % is code layout, not a new branch on that path: the 37-byte
one-shot `typical` decode gained no work, and the same reader change that costs
it those 29 instructions saves 3 461 on the 9 kB one-shot array.

No API, behaviour or wire-format change: both decode surfaces still produce the
same visitor calls and the same `DecodeStatus`, and no spec-mandated check was
weakened to get here — the fast paths *decline* anything they cannot settle
(a varint that does not terminate in the chunk, a malformed 10-byte varint) and
hand those bytes back to the byte-wise reader, which owns the
INCOMPLETE/INVALID verdict as before.

* Tests: `test/chunk_fast_path_test.dart` runs each of 14 messages — 1000-element
  arrays of 9- and 10-byte varints, scalars of every varint length, payloads
  longer than a chunk, malformed and truncated arrays, invalid UTF-8 — through
  `feed` at 13 chunk sizes and asserts the events *and* the status match the
  one-shot decode exactly, so no chunking can take a different route to a
  different answer. Added with it: a declared element width violated anywhere
  inside a bulk run, two decoders interleaving a split float payload, a
  non-`Uint8List` chunk, and (in `invalid_utf8_test.dart`) the encoder rollback
  that keeps a rejected string from committing a held-back sequence frame.

### CI — the release (AOT) configuration is now built and run (§12.1)

`ci.yml` ran `dart pub get`, `dart format`, `dart analyze`, `dart test` and a
`dart run` sanity pass — all of which are the **debug** (JIT) configuration.
`dart compile exe` appeared nowhere, so the AOT toolchain was never exercised:
an AOT-only failure would have shipped unnoticed, and `bench/run_bench.sh` and
`bench/run_callgrind.sh` — the two scripts the README names as the recommended
way to benchmark, both of which drive `dart compile exe` — were never executed,
so a break in either script, or in `bench/callgrind_target.dart`, stayed
invisible until someone ran it by hand.

* The `stable` matrix leg gained a release step that runs both benchmark
  scripts, which between them AOT-compile `bench/bench.dart`, `bench/perf.dart`
  and `bench/callgrind_target.dart` and then run the executables (installing
  `valgrind` only if the runner image lacks it). One SDK is enough — the matrix
  exists for language-version drift, not for the AOT toolchain. The JIT step is
  kept and relabelled, so both configurations are built as §12.1 requires.
* No library, API or wire-format change; `build/` stays git-ignored.
* Tests: `test/ci_release_build_test.dart` reads the AOT entrypoints out of
  `bench/*.sh` — it invents no list — and fails unless CI builds every one of
  them and runs every benchmark script the README recommends. Adding an AOT
  entrypoint without teaching CI about it now fails the suite. Closes #46.

### Docs — `### Requirements` names the SDK floor that is actually enforced (§9.2)

The README promised **Dart SDK ≥ 3.4.0** while `pubspec.yaml` requires
`^3.8.0` and the CI matrix's lowest leg is `3.8`. A reader on 3.4–3.7 followed
the README's install command and got a resolution failure instead of a library.

* The Requirements bullet now states **≥ 3.8.0** and says where the number
  comes from — the `environment.sdk` bound and the lowest CI leg, i.e. the
  oldest SDK this port is proven on.
* No behaviour, API or wire-format change; the enforced floor did not move.
* Tests: `test/sdk_floor_test.dart` parses `pubspec.yaml`, the README's
  Requirements section and `.github/workflows/ci.yml`, and fails the moment the
  three disagree — so the next bump of `environment.sdk` cannot silently leave
  the README behind. It also re-asserts §9.2's install command. Closes #45.

### Docs — `## Memory handling` states what one-shot decode does with your bytes (§9.6)

The section described the streaming surface only, and got the one-shot surface
backwards by omission: the table row said a decoded `blob` "may reference a
freshly-allocated payload buffer", while `Decoder.decode` hands `onBlob` and
`onStringBytes` a `Uint8List` **view** onto the caller's input buffer. A caller
who retained such a value and then reused its own buffer saw the retained bytes
change under it. CORELIB_PLAN §9.6 requires exactly this statement, per surface.

* The owner/lifetime table now carries a row per decode surface, and two bullets
  replace the single mixed one: `Decoder.decode` **borrows** — views valid only
  while the buffer is alive and unmodified, `Uint8List.fromList` to retain,
  `onString` always a fresh copy, a non-`Uint8List` `List<int>` copied once up
  front and therefore never aliased; `Decoder.feed` **copies out** — a fed chunk
  is reusable the moment `feed` returns, whatever the chunking (§6).
* `MessageVisitor.onBlob` gained the borrowed-value note `onStringBytes` already
  carried.
* No behaviour, API or wire-format change.
* Tests: `test/decode_ownership_test.dart` pins both surfaces by mutating the
  caller's bytes after delivery — aliased on the one-shot path, never on the
  streamed one — and reads the README section back, failing if it stops stating
  either rule. Closes #44.

### Performance — a streamed fixlen array is allocated once, and filled in bulk

Streaming decode of an `array<fp32>` / `array<fp64>` allocated the payload
**twice**: a byte-sized staging buffer that the state machine filled one byte
per dispatch, plus the `Float32List`/`Float64List` it was then copied into. Peak
memory was 2× the payload and every element was touched twice — on a port whose
one-shot path never did either.

* The result list *is* the staging buffer now. A fixlen payload already is that
  list's little-endian byte image, so the arriving bytes go straight into its
  storage (`Uint8List.sublistView`) and delivery copies nothing. Peak memory is
  one array. A big-endian host — none exists among Dart's targets — keeps the
  separate buffer and the element-wise conversion.
* `Decoder.feed` now moves a payload run — `string`, `blob`, `fp32`/`fp64` and
  fixlen-array elements alike — in one bounded `setRange` per chunk instead of
  one state-machine dispatch per byte, whenever at least four bytes are on
  offer. The last byte of every payload still goes through the per-byte step, so
  completion is decided in one place. Measured on a 1000-element `array<fp64>`
  fed in 4 KiB chunks (AOT): **~66 → ~1.2 µs/op**, and ~10× at 64-byte chunks. A
  byte-at-a-time feed of the same array pays ~20% for the halved memory, the
  trade this port wants at that chunk size.
* No API, wire-format or visitor-order change. `fp64` array elements now reach
  the visitor without passing through a `double` conversion at all, as `fp32`
  elements already did (§4.6 / §6.5).
* Tests: `test/fixlen_array_staging_test.dart` — peak memory measured in a child
  VM under an old-generation heap cap sized for one copy, plus bit-exact
  fp32/fp64 streaming at chunk sizes 1/3/7/8/64, back-to-back arrays, skipped
  arrays and `List<int>` chunks. The shared-vector `chunked-decode` leg now
  replays every vector at chunk sizes 2/3/5/16/4096 as well as byte-at-a-time.
  Closes #43.

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
