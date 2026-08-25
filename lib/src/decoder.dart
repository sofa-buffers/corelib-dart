import 'dart:typed_data';

import 'utf8.dart';
import 'wire.dart';

/// A push-feed / pull-read consumer of a SofaBuffers stream (CORELIB_PLAN §5.2,
/// §5.3 — the *visitor* pattern, preferred for object-capable languages).
///
/// The decoder calls these methods as fields complete. [shouldRead] is consulted
/// at **header time**, before any payload is consumed: return `false` to skip the
/// field (a length jump — the payload is neither materialized nor UTF-8-validated,
/// CORELIB_PLAN §6.4). For a nested sequence, [onSequenceStart] returns a child
/// visitor to descend, or `null` to skip the whole sub-sequence.
///
/// Booleans arrive via [onUnsigned] (`0`/`1`) — booleans have no wire type
/// (CORELIB_PLAN §4.4); the consumer interprets them. Integer array element width
/// is an API concern, so arrays arrive as 64-bit values.
/// Raised by [MessageVisitor.invalidate] and caught by whichever decode engine
/// is running, which then reports `INVALID` and stops.
///
/// Private on purpose: it is a control signal, not an error a caller handles.
/// It is also the reason a visitor callback must not swallow exceptions
/// indiscriminately — a bare `catch` around a store would eat the verdict.
class _Invalidated implements Exception {
  const _Invalidated();
}

/// Raised by [MessageVisitor.limitExceeded] and caught by whichever decode
/// engine is running, which then reports `limitExceeded` and stops.
///
/// A second control signal rather than a flag on the first, because
/// CORELIB_PLAN §6.2.1 forbids folding a receiver-limit breach into `INVALID`:
/// *"exceeding one is a policy rejection — a category distinct from INVALID …
/// An implementation MUST NOT report it as `InvalidMessage`"*. The two travel
/// the same way and arrive as different outcomes.
class _LimitExceeded implements Exception {
  const _LimitExceeded();
}

abstract class MessageVisitor {
  /// Whether to read (materialize) the leaf field, or skip it. Default: read.
  bool shouldRead(int id, int type) => true;

  /// Reject the running decode as `INVALID` from inside a callback.
  ///
  /// The wire layer judges what the format can decide on its own; a **schema**
  /// bound — an array index past the declared capacity, a string past its
  /// `maxlen`, a value outside its declared width — is knowable only to the
  /// consumer, and MESSAGE_SPEC §7.1 makes it INVALID all the same. Callbacks
  /// return `void`, so without this a consumer had nowhere to put that verdict
  /// and had to carry a flag of its own, converted after the decode returned.
  ///
  /// Calling this stops the decode where it stands: no further field is
  /// delivered, and [Decoder.feed] / [Decoder.decode] report
  /// [DecodeStatus.invalid], which is terminal (CORELIB_PLAN §5.2). That is the
  /// difference from a flag read afterwards — the verdict was already right,
  /// but the bytes behind it were still being parsed and delivered.
  ///
  /// Safe from any depth, including inside a nested collector. It never
  /// returns normally.
  void invalidate() => throw const _Invalidated();

  /// Reject the running decode as [DecodeStatus.limitExceeded] from inside a
  /// callback — the receiver-cap counterpart of [invalidate].
  ///
  /// A **configured receiver limit** (CORELIB_PLAN §6.2.1) is not a statement
  /// about the bytes: they are well-formed, and the same message decodes for a
  /// receiver configured more loosely. §6.2.1 therefore forbids folding a
  /// breach into `INVALID`, and §6.3 keeps `LimitExceeded` distinct so a caller
  /// can tell *"raise my limit, or the sender must send less"* from *"these
  /// bytes are broken"*.
  ///
  /// The decoder raises it itself at a count or length header
  /// ([DecoderLimits]). This is the channel for the one bound the decoder
  /// cannot see: a **wrapper array's element index**, which is the array's
  /// length (MESSAGE_SPEC §5.1) and is checked where the elements are
  /// collected — `lib/src/seq.dart`, or a generated visitor doing the same job.
  /// Without it a collector's only refusal was [invalidate], which reports the
  /// wrong category.
  ///
  /// Safe from any depth. It never returns normally.
  void limitExceeded() => throw const _LimitExceeded();

  void onUnsigned(int id, int value) {}
  void onSigned(int id, int value) {}
  void onFp32(int id, double value) {}

  /// Delivered for an fp32 field whose payload is a **NaN**, carrying the raw
  /// 32-bit IEEE-754 bit pattern so a signaling NaN survives bit-for-bit — a
  /// Dart `double` would quiet it (CORELIB_PLAN §4.6: never normalize). The
  /// default widens to a `double` and forwards to [onFp32], so a consumer that
  /// does not care about NaN bit patterns needs no change; override this to
  /// capture the exact bits (and re-emit them with `Encoder.writeFp32Bits`).
  void onFp32Bits(int id, int bits) {
    final b = ByteData(4)..setUint32(0, bits, Endian.little);
    onFp32(id, b.getFloat32(0, Endian.little));
  }

  void onFp64(int id, double value) {}

  /// A `string` field was materialized and its bytes are valid UTF-8.
  ///
  /// This is a convenience layered on [onStringBytes]: it fires from that
  /// method's **default** implementation, which validates the wire bytes and
  /// transcodes them. A visitor that overrides [onStringBytes] owns the whole
  /// string path and this method is then never called by the decoder.
  void onString(int id, String value) {}

  /// A `string` field was materialized, carrying its **raw wire bytes** —
  /// un-validated and un-transcoded (CORELIB_PLAN §6.4).
  ///
  /// This is the decoder's string path. It fires only for a field that is being
  /// read into a destination: a skipped `string` (an id the consumer declined
  /// via [shouldRead], an id inside a skipped sub-sequence, or any payload the
  /// consumer discards) is a length jump whose bytes are never inspected, so it
  /// never reaches here and is never UTF-8-validated — §6.4's *"skipped fields
  /// are never validated"*, which MESSAGE_SPEC §7.3 extends to a field whose
  /// wire type/subtype contradicts the schema.
  ///
  /// **Schema-bound (generated) consumers override this**, resolve the
  /// destination for `id` *first*, and call [decodeUtf8Strict] only inside a
  /// matched destination arm — an unmatched id must return without validating
  /// and without flagging INVALID, which is what `VisitorBase` is for: extend
  /// it and every id the scope does not declare already skips. A Dart `String`
  /// cannot carry invalid bytes without the lossy U+FFFD substitution §6.4
  /// forbids, so delivering the raw bytes is the only way a push consumer can
  /// honour the materialize-only rule. Such an override reports a rejected
  /// payload through its own sticky INVALID flag, exactly as it already does
  /// for a schema `maxlen` breach seen in [onFixlenHeader].
  ///
  /// The default implementation preserves the always-strict behaviour of this
  /// port for hand-written visitors: invalid UTF-8 at a materialized position
  /// fails the decode with [DecodeStatus.invalid], and valid bytes are decoded
  /// and forwarded to [onString].
  ///
  /// [bytes] is the destination [onBytesDest] handed over, filled: the
  /// **caller's** storage on both decode surfaces, aliasing nothing the decoder
  /// was fed (CORELIB_PLAN §6.7.1 — "`decode(buffer)` copies too").
  void onStringBytes(int id, Uint8List bytes) {
    // One scan, ASCII fast path included — see [decodeUtf8Strict], which is the
    // same call a generated override makes inside a matched arm.
    final value = decodeUtf8Strict(bytes);
    if (value == null) {
      _stringRejected = true;
      return;
    }
    onString(id, value);
  }

  // Set by the default [onStringBytes] when the payload is not valid UTF-8, and
  // consumed by `_deliverPayload` below. An override never touches it: a
  // schema-bound consumer carries its own sticky INVALID flag.
  bool _stringRejected = false;

  /// [value] is the destination [onBytesDest] handed over, filled — the
  /// caller's own storage, on either decode surface.
  void onBlob(int id, Uint8List value) {}

  /// The four whole-aggregate conveniences, fired by the default [onArrayDone]
  /// with the destination [onArrayDest] handed over. A consumer that supplies
  /// its own destination overrides [onArrayDone] instead and never sees these.
  void onUnsignedArray(int id, Int64List values) {}
  void onSignedArray(int id, Int64List values) {}
  void onFp32Array(int id, Float32List values) {}
  void onFp64Array(int id, Float64List values) {}

  /// The destination a `string`/`blob` payload is written into — **the
  /// caller's storage**, asked for at the `fixlen_word`, before a single
  /// payload byte is consumed and before any truncation is known.
  ///
  /// This is CORELIB_PLAN §6.6.3's second shape: *"into a destination the
  /// caller hands back after being told the announced count, with the codec
  /// refusing a destination too short rather than growing it"*. The codec owns
  /// no payload storage (§6.6) and hands out nothing that outlives the callback
  /// (§6.7), so the only place a payload can land is memory this method
  /// returns. A payload split across `feed` calls is joined *here*, piece by
  /// piece as each piece arrives (§6.6.2) — there is no library-owned carry
  /// buffer.
  ///
  /// * [total] is the payload's whole length in bytes, already past the schema
  ///   bound ([onFixlenHeader]) and the receiver cap ([DecoderLimits]).
  /// * Return a list of **at least [total] bytes**. A shorter one is a mistake
  ///   in the *call*, not in the message: the decode fails with
  ///   [SofabError.invalidArgument] (§6.3's third refusal tier) rather than
  ///   `InvalidMessage` or `LimitExceeded`, and the decoder never grows what it
  ///   was handed.
  /// * Return `null` to **decline** the payload. The field is then walked like
  ///   a skipped one — nothing is materialized, nothing is UTF-8-validated
  ///   (§6.4.5), and [onBytesDone] does not fire.
  ///
  /// [subtype] is [FixlenType.string] or [FixlenType.blob]; `fp32`/`fp64`
  /// values land in the decoder's own 8-byte landing zone and never come here.
  ///
  /// The default allocates one exactly-sized list per payload and is the
  /// **caller's** allocation, not the codec's: it runs inside a callback the
  /// codec made, on storage the codec hands straight back (§6.6.1 — "the
  /// boundary is ownership, not the stack"). It is what makes [onString],
  /// [onStringBytes] and [onBlob] work for a hand-written visitor. A consumer
  /// that owns its storage — generated code, a pooled buffer, a caller decoding
  /// into a fixed record — overrides this and the codec allocates nothing at
  /// all.
  Uint8List? onBytesDest(int id, int subtype, int total) =>
      total == 0 ? _noBytes : Uint8List(total);

  /// The `string`/`blob` payload is complete in [dest] — the very list
  /// [onBytesDest] returned, with its first [total] bytes written.
  ///
  /// Fires once per payload, however the bytes arrived. The default splits the
  /// two subtypes onto [onStringBytes] (which validates and transcodes) and
  /// [onBlob]; a consumer that supplied its own destination usually has nothing
  /// left to do here and overrides this to a no-op.
  void onBytesDone(int id, int subtype, Uint8List dest, int total) {
    final bytes = dest.length == total
        ? dest
        : Uint8List.sublistView(dest, 0, total);
    if (subtype == FixlenType.string) {
      onStringBytes(id, bytes);
    } else {
      onBlob(id, bytes);
    }
  }

  /// The destination an **array** payload is decoded into — the caller's
  /// storage, asked for once per array field after [onArrayBegin], before any
  /// element is consumed. The array counterpart of [onBytesDest], and the same
  /// clause: §6.6.3, shape B.
  ///
  /// The list must match [kind] and hold at least [count] elements:
  ///
  /// | kind | destination |
  /// |---|---|
  /// | [ArrayKind.unsigned] / [ArrayKind.signed] | `Int64List` |
  /// | [ArrayKind.fp32] | `Float32List` |
  /// | [ArrayKind.fp64] | `Float64List` |
  ///
  /// A shorter list, or one of the wrong type, fails the decode with
  /// [SofabError.invalidArgument] (§6.3) — the decoder neither grows it nor
  /// silently writes fewer elements. `null` declines the field, which is then
  /// walked like a skipped one and never delivered.
  ///
  /// The two float kinds take a typed list rather than a `double` sink for a
  /// reason beyond speed: the wire bytes are copied into the list's own
  /// storage, so a signaling or payload `NaN` survives bit-for-bit (§4.6,
  /// §6.5), where widening through a Dart `double` would quiet it.
  ///
  /// The default allocates an exactly-sized list — again the caller's
  /// allocation, made inside the callback (§6.6.1) — so [onUnsignedArray] and
  /// its three siblings keep working unchanged.
  TypedData? onArrayDest(int id, ArrayKind kind, int count) {
    switch (kind) {
      case ArrayKind.unsigned:
      case ArrayKind.signed:
        return Int64List(count);
      case ArrayKind.fp32:
        return Float32List(count);
      case ArrayKind.fp64:
        return Float64List(count);
    }
  }

  /// The array is complete in [dest] — the very list [onArrayDest] returned,
  /// with its first [count] elements written.
  ///
  /// The default forwards to the whole-aggregate convenience for [kind]. A
  /// consumer that supplied its own destination overrides this (often to a
  /// no-op: the elements are already where it wanted them).
  void onArrayDone(int id, ArrayKind kind, TypedData dest, int count) {
    switch (kind) {
      case ArrayKind.unsigned:
        final v = dest as Int64List;
        onUnsignedArray(
          id,
          v.length == count ? v : Int64List.sublistView(v, 0, count),
        );
      case ArrayKind.signed:
        final v = dest as Int64List;
        onSignedArray(
          id,
          v.length == count ? v : Int64List.sublistView(v, 0, count),
        );
      case ArrayKind.fp32:
        final v = dest as Float32List;
        onFp32Array(
          id,
          v.length == count ? v : Float32List.sublistView(v, 0, count),
        );
      case ArrayKind.fp64:
        final v = dest as Float64List;
        onFp64Array(
          id,
          v.length == count ? v : Float64List.sublistView(v, 0, count),
        );
    }
  }

  /// Called **once** per array field, for every array kind, with the wire
  /// element [count] and the element [kind] — *before* any element is consumed
  /// and *before* the truncation check. Fires only for a field being read (never
  /// a skipped one, matching the whole-array callbacks), and never per element.
  ///
  /// **Where it fires** (CORELIB_PLAN §4.8):
  ///
  /// * for an integer array (`arrayUnsigned` / `arraySigned`) — the instant the
  ///   `count` varint is read; there is no second word;
  /// * for a fixlen array (`arrayFixlen`) — after the `fixlen_word` has been read
  ///   *and* validated as a format matter, so [kind] is the real element subtype
  ///   ([ArrayKind.fp32] or [ArrayKind.fp64]), never a collapsed "fixlen".
  ///
  /// That ordering is required, not incidental. A fixlen array whose element
  /// subtype contradicts the declared element type is a **skipped** field
  /// (MESSAGE_SPEC §7.3) and was never this field's value, so its element count
  /// is not this field's count and the schema `count` bound MUST NOT be applied
  /// to it. Only a header whose [kind] matches the declared element type gets the
  /// bound. A message that ends *between* the two words is therefore INCOMPLETE,
  /// not INVALID — the decoder cannot yet know which field it is looking at.
  ///
  /// A schema-bound consumer overrides this to reject `count > N` at the header
  /// — inside the arm that matches the declared [kind]: setting its own sticky
  /// INVALID flag here makes INVALID dominate a truncated tail (MESSAGE_SPEC §5.2
  /// anti-folding), which the post-assembly
  /// [onUnsignedArray]/[onSignedArray]/[onFp32Array]/[onFp64Array] guard cannot —
  /// a truncated array never reaches those. Default: no-op.
  ///
  /// A zero-count fixlen array still carries its `fixlen_word`, so the hook still
  /// fires exactly once with the correct [kind] and `count == 0`.
  void onArrayBegin(int id, ArrayKind kind, int count) {}

  /// The inclusive value range an element of the **integer array** field [id]
  /// may take under the schema, or `null` when the field declares no width
  /// narrower than the 64-bit value domain (`u64`/`i64`, an enum or bitfield
  /// element, or an id this visitor does not declare).
  ///
  /// Asked **once per array field**, at the count word, never per element; the
  /// decoder then applies the range as the elements go past.
  ///
  /// It exists because the whole-array callbacks cannot answer in time. A
  /// declared width is a validity bound (MESSAGE_SPEC §7.1) and §5.2 makes
  /// INVALID dominate INCOMPLETE, so an element already outside its width keeps
  /// the message INVALID however little follows it — but a guard over the
  /// assembled [onSignedArray]/[onUnsignedArray] list only runs for an array
  /// that ARRIVES, and the array in question is precisely one that does not.
  /// Same shape as [onArrayBegin] one level down: only the decoder sees the
  /// element in time, only the schema knows the bound (generator#267, Crucible
  /// F-0043).
  ///
  /// [kind] is the kind the WIRE declares. Return `null` for a kind this field
  /// does not declare: an array whose element kind contradicts the schema is a
  /// skipped field (§7.3) and its elements were never this field's value, so
  /// this field's width must not be measured against them — the rule
  /// [onArrayBegin] states for the count bound, one level down again.
  ///
  /// Return a `const` [ElemRange] to keep this allocation-free. Default: none.
  ElemRange? onArrayElemBound(int id, ArrayKind kind) => null;

  /// The element `count` the **schema** declares for the array field [id], or
  /// `null` when the schema leaves it unbounded (`count:` omitted — MESSAGE_SPEC
  /// §7.2 — or an id/[kind] this visitor does not declare).
  ///
  /// This is how a schema-bound consumer takes the receiver-side cap
  /// ([DecoderLimits.maxArrayCount]) **off** one of its fields. The two are
  /// different kinds of statement (CORELIB_PLAN §6.2.1): a cap is deployment
  /// configuration protecting the receiver from a field the schema leaves
  /// unbounded, and it "MUST NOT be applied to a field the schema already
  /// bounds. There the schema bound governs and its violation is `INVALID`"
  /// (MESSAGE_SPEC §7, §7.1) — §6.3 says the same from the other end:
  /// `LimitExceeded` is "never raised for a field the schema bounds". Only the
  /// schema knows which fields those are, so only the consumer can answer.
  /// Without this the decode of a `count: 10000` array would depend on a
  /// deployment cap of 1000 that was never meant for it.
  ///
  /// Answering is therefore a *swap*, not a waiver: the decoder stops measuring
  /// the field against the cap and measures it against the returned bound
  /// instead, and a wire count past that bound is [DecodeStatus.invalid] — the
  /// outcome §7.1 wants there — decided at the count word, before any element
  /// is consumed and before the allocation.
  ///
  /// [kind] is the kind the WIRE declares. Return `null` for a kind this field
  /// does not declare: such an array is a skipped field (MESSAGE_SPEC §7.3) and
  /// was never this field's value, so this field's `count` must not be measured
  /// against it — and the cap, which covers exactly what no schema bound does,
  /// still applies to it. Same rule as [onArrayBegin] and [onArrayElemBound].
  ///
  /// Asked at most once per array field, and only where the answer can change
  /// an outcome: the decoder consults it just after a configured cap has been
  /// exceeded, never on the path where no cap is set or the count fits. A
  /// decode with no [DecoderLimits] therefore pays nothing for it — there the
  /// schema bound is the consumer's own [onArrayBegin] check, as before.
  /// Default: unbounded.
  int? onArrayCountBound(int id, ArrayKind kind) => null;

  /// Called with a fixlen value's declared byte `length` and `subtype`
  /// ([FixlenType]) the instant its length word is read — *before* the payload
  /// and *before* the truncation check. Fires only for a field being read.
  ///
  /// A schema-bound consumer overrides this to reject `length > maxlen` at the
  /// header (INVALID then dominates a truncated payload, §5.2). For a string the
  /// wire `length` is exactly the UTF-8 byte length, so the check is exact and
  /// lets the generator drop the redundant post-decode length guard. Default:
  /// no-op.
  void onFixlenHeader(int id, int subtype, int length) {}

  /// The `maxlen` the **schema** declares for the `string`/`blob` field [id], or
  /// `null` when the schema leaves it unbounded (`maxlen:` omitted, or an
  /// id/[subtype] this visitor does not declare).
  ///
  /// The fixlen counterpart of [onArrayCountBound], with the same contract:
  /// answering takes the receiver-side cap ([DecoderLimits.maxStringLen] /
  /// [DecoderLimits.maxBlobLen]) off the field and puts the schema bound in its
  /// place, so a length past the bound is [DecodeStatus.invalid] (MESSAGE_SPEC
  /// §7.1) rather than [DecodeStatus.limitExceeded] — which §6.3 forbids for a
  /// field the schema bounds. Decided at the length word, before the payload.
  ///
  /// [subtype] is the subtype the WIRE declares ([FixlenType.string] /
  /// [FixlenType.blob]; the fp32/fp64 subtypes have a fixed 4/8-byte length, so
  /// no cap covers them and this is never asked for one). Return `null` for a
  /// subtype this field does not declare — that is a MESSAGE_SPEC §7.3 skip and
  /// this field's `maxlen` does not govern it.
  ///
  /// Asked at most once per field, and only just after a configured cap has
  /// been exceeded, so a decode with no [DecoderLimits] pays nothing for it.
  /// Default: unbounded.
  int? onFixlenLenBound(int id, int subtype) => null;

  /// A sequence opened. Return a visitor for its children (which follows the
  /// same push/pull contract recursively), or `null` to skip the sub-sequence.
  /// Default: descend, reusing this visitor — the right default for a
  /// hand-written visitor, and the wrong one for a schema-bound consumer, which
  /// binds only the sequences its schema declares and therefore starts from
  /// `VisitorBase` instead.
  MessageVisitor? onSequenceStart(int id) => this;

  /// The sequence whose children this visitor received has closed.
  void onSequenceEnd() {}
}

/// The inclusive range an integer array's elements may take under the schema —
/// the answer to [MessageVisitor.onArrayElemBound].
///
/// Both bounds are `int`, which is what the decoder produces: a signed element
/// arrives zig-zag-decoded, an unsigned one raw, and Dart's `int` is the same
/// 64-bit two's-complement word either way.
///
/// The widest NARROWED unsigned kind is `u32`, so [max] never reaches 2^63 and
/// an unsigned wire value whose top bit is set — which Dart's `int` shows as
/// negative — is always out of range. That is why the unsigned comparison reads
/// `raw < 0 || raw > max` rather than `raw > max`: an unsigned compare, written
/// in a language without one.
class ElemRange {
  final int min;
  final int max;
  const ElemRange(this.min, this.max);
}

/// Hands a completed `string`/`blob` payload back to [vis] in the destination it
/// supplied. Returns `false` when the *default* [MessageVisitor.onStringBytes]
/// rejected the bytes as invalid UTF-8; an override signals a rejection through
/// its own sticky flag instead, so this always returns `true` for one.
bool _deliverPayload(
  MessageVisitor vis,
  int id,
  int subtype,
  Uint8List dest,
  int total,
) {
  vis.onBytesDone(id, subtype, dest, total);
  if (!vis._stringRejected) return true;
  vis._stringRejected = false; // leave the visitor reusable for a fresh decode
  return false;
}

/// Asks [vis] for the destination of a `string`/`blob` payload and checks what
/// comes back (CORELIB_PLAN §6.6.3, §6.3).
///
/// `null` means the caller declined and the payload is walked. A destination
/// **too short for the announced length** is the third refusal tier: the
/// message is well-formed and within every bound it declares, so it is neither
/// `InvalidMessage` nor `LimitExceeded` but [SofabError.invalidArgument] — a
/// mistake in the call. The decoder never grows what it was handed.
Uint8List? _bytesDest(MessageVisitor vis, int id, int subtype, int total) {
  final dest = vis.onBytesDest(id, subtype, total);
  if (dest == null) return null;
  if (dest.length < total) {
    throw SofabException(
      SofabError.invalidArgument,
      'destination for field $id holds ${dest.length} bytes, '
      'the payload announces $total',
    );
  }
  return dest;
}

/// The array counterpart of [_bytesDest]: asks for the destination and checks
/// that it is long enough **and** of the type [kind] requires. Both failures are
/// [SofabError.invalidArgument] (§6.3) — the call is wrong, not the message.
TypedData? _arrayDest(MessageVisitor vis, int id, ArrayKind kind, int count) {
  final dest = vis.onArrayDest(id, kind, count);
  if (dest == null) return null;
  final bool typed;
  switch (kind) {
    case ArrayKind.unsigned:
    case ArrayKind.signed:
      typed = dest is Int64List;
    case ArrayKind.fp32:
      typed = dest is Float32List;
    case ArrayKind.fp64:
      typed = dest is Float64List;
  }
  if (!typed) {
    throw SofabException(
      SofabError.invalidArgument,
      'destination for array field $id does not match element kind '
      '${kind.name}',
    );
  }
  if (dest.lengthInBytes < count * dest.elementSizeInBytes) {
    throw SofabException(
      SofabError.invalidArgument,
      'destination for array field $id holds '
      '${dest.lengthInBytes ~/ dest.elementSizeInBytes} elements, '
      'the array announces $count',
    );
  }
  return dest;
}

/// Configured receiver-side technical limits (CORELIB_PLAN §6.2.1). These are a
/// deployment **policy**, not schema validity: exceeding one yields
/// [DecodeStatus.limitExceeded], never [DecodeStatus.invalid].
///
/// **There is no unset state and no unlimited mode** (§6.2.1). All three caps
/// are finite, and a decoder built without a [DecoderLimits] carries the
/// [defaultMaxDynArrayCount] / [defaultMaxDynStringLen] / [defaultMaxDynBlobLen]
/// defaults rather than nothing: *"Unbounded by the schema is still bounded by
/// the receiver."* A deployment that wants other numbers passes them — the
/// values belong to generated code, which knows the schema and the target — but
/// it cannot pass "none".
///
/// They are the backstop for the fields the **schema** leaves unbounded, and
/// only those. §6.2.1: a limit "MUST NOT be applied to a field the schema
/// already bounds. There the schema bound governs and its violation is
/// `INVALID`". A schema-bound consumer says which fields those are through
/// [MessageVisitor.onArrayCountBound] / [MessageVisitor.onFixlenLenBound]; for
/// a field that answers, the declared bound replaces the limit below and a
/// breach of it is [DecodeStatus.invalid].
class DecoderLimits {
  /// Every cap is finite and every one has a default; passing a negative value
  /// is rejected rather than read as "unlimited" (§6.2.1).
  const DecoderLimits({
    this.maxArrayCount = defaultMaxDynArrayCount,
    this.maxStringLen = defaultMaxDynStringLen,
    this.maxBlobLen = defaultMaxDynBlobLen,
  }) : assert(maxArrayCount >= 0, 'maxArrayCount must not be negative'),
       assert(maxStringLen >= 0, 'maxStringLen must not be negative'),
       assert(maxBlobLen >= 0, 'maxBlobLen must not be negative');

  /// Elements in a schema-unbounded array.
  final int maxArrayCount;

  /// Bytes in a schema-unbounded `string`.
  final int maxStringLen;

  /// Bytes in a schema-unbounded `blob`.
  final int maxBlobLen;
}

/// Weighs an array's wire [count] against the receiver-side cap and, where the
/// schema bounds the field, against that bound instead (CORELIB_PLAN §6.2.1,
/// §6.3). Returns the terminal status to fail with, or `null` when the field may
/// proceed.
///
/// Called at the count word — for a fixlen array, at the `fixlen_word` that
/// settles [kind] — i.e. before the allocation the cap exists to prevent, and
/// only for a field being materialized: a skipped field allocates nothing.
/// [MessageVisitor.onArrayCountBound] is asked only once the cap is already
/// exceeded, which is the only place its answer changes an outcome.
DecodeStatus? _arrayCountVerdict(
  MessageVisitor vis,
  DecoderLimits limits,
  int id,
  ArrayKind kind,
  int count,
) {
  if (count <= limits.maxArrayCount) return null;
  final bound = vis.onArrayCountBound(id, kind);
  // No schema bound on this field: the cap applies, as a policy rejection.
  if (bound == null) return DecodeStatus.limitExceeded;
  // Schema-bounded: the cap is off this field and the declared bound decides.
  return count > bound ? DecodeStatus.invalid : null;
}

/// The fixlen counterpart of [_arrayCountVerdict], at the `fixlen_word`. Only
/// `string`/`blob` carry a configurable cap — an fp32/fp64 length is fixed at
/// 4/8 bytes by the format and was validated as such above.
DecodeStatus? _fixlenLenVerdict(
  MessageVisitor vis,
  DecoderLimits limits,
  int id,
  int subtype,
  int length,
) {
  final int cap;
  if (subtype == FixlenType.string) {
    cap = limits.maxStringLen;
  } else if (subtype == FixlenType.blob) {
    cap = limits.maxBlobLen;
  } else {
    return null;
  }
  if (length <= cap) return null;
  final bound = vis.onFixlenLenBound(id, subtype);
  if (bound == null) return DecodeStatus.limitExceeded;
  return length > bound ? DecodeStatus.invalid : null;
}

// Internal decoder states. The two *payload* states are deliberately last and
// adjacent: they are the only ones whose bytes are opaque — no varint to
// accumulate, nothing to decide per byte — so [Decoder.feed] moves them in bulk
// and [Decoder._step] splits them off with one compare. Every other state is
// waiting for a varint, which is what lets `< _sFixPayload` stand for "a whole
// varint may be lifted straight out of the chunk".
const int _sHeader = 0;
const int _sUValue = 1; // unsigned value varint
const int _sSValue = 2; // signed value varint
const int _sFixWord = 3;
const int _sArrCount = 4; // count for int arrays (u/s)
const int _sArrElem = 5; // per-element varint for int arrays
const int _sArrFixCount = 6;
const int _sArrFixWord = 7;
const int _sFixPayload = 8; // opaque payload — bulk-copied
const int _sArrFixPayload = 9; // opaque payload — bulk-copied

/// Shortest run of payload bytes worth moving in bulk (see
/// [Decoder._bulkPayload]).
const int _bulkPayloadMin = 4;

/// Fewest chunk bytes worth entering the word-wise array-element run for (see
/// [Decoder._bulkArrElems]): one maximal varint, the reader's step size.
const int _bulkVarintMin = 10;

/// The empty payload every zero-length `string`/`blob` is delivered as — one
/// object for the whole isolate rather than one per field.
final Uint8List _noBytes = Uint8List(0);

/// The continuation bit of all eight bytes of a 64-bit word.
const int _contBits = 0x8080808080808080;

/// Shared 8-byte staging area for reading a **single** IEEE-754 payload.
///
/// Dart offers no bits→double conversion outside typed data, and building a view
/// over the input costs ~300 instructions — far more than a scalar float read is
/// worth. Copying the 4/8 payload bytes into this one permanently-allocated
/// scratch and reading them back is several times cheaper, and it keeps a
/// float-carrying message from paying for a whole-buffer view it needs nowhere
/// else. Array payloads still use the buffer-wide view, where it amortizes.
///
/// Isolate-confined (Dart statics are per-isolate) and live only for the
/// duration of one read, so there is no sharing hazard.
final Uint8List _scratchBytes = Uint8List(8);
final ByteData _scratchData = ByteData.view(_scratchBytes.buffer);

/// Gathers eight 7-bit groups — one per byte of [x], little-endian — back into
/// the low 56 bits of a value. The inverse of the encoder's spread step, and the
/// core of the word-wise varint reader ([_ContiguousDecoder._uvarintWide]).
/// Three log-steps rather than eight shift-mask-or terms — merge adjacent 7-bit
/// groups into 14s, then 28s, then the full 56. 12 operations instead of 23.
@pragma('vm:prefer-inline')
int _unspread56(int x) {
  var v = (x & 0x007F007F007F007F) | ((x & 0x7F007F007F007F00) >>> 1);
  v = (v & 0x00003FFF00003FFF) | ((v & 0x3FFF00003FFF0000) >>> 2);
  return (v & 0xFFFFFFF) | ((v & 0x0FFFFFFF00000000) >>> 4);
}

/// Index (0..7) of the byte holding the lowest set bit of [m], where [m] only
/// ever has bits at the eight `0x80` positions — i.e. the varint's terminating
/// byte.
///
/// A three-step binary search rather than `bitLength`: `bitLength` is a real
/// method call under Dart AOT (not a count-leading-zeros intrinsic) and measured
/// ~2× the cost of the whole surrounding loop.
@pragma('vm:prefer-inline')
int _termByte(int m) {
  var idx = 0;
  var x = m;
  if ((x & 0xFFFFFFFF) == 0) {
    idx = 4;
    x >>>= 32;
  }
  if ((x & 0xFFFF) == 0) {
    idx += 2;
    x >>>= 16;
  }
  if ((x & 0xFF) == 0) idx += 1;
  return idx;
}

/// Decodes a run of array-element varints (CORELIB_PLAN §4.7) **word-wise** —
/// the shared element engine of both decode surfaces, so the one-shot path and
/// the streaming path cost the same per element and cannot drift apart.
///
/// Reads from [buf] (viewed as [bd], valid to [len]) starting at [p] and fills
/// `out[i..limit)`. Returns the position it stopped at in the low 32 bits and
/// the index it stopped at in the high bits — a packed pair rather than a record
/// so the run itself allocates nothing; both fit comfortably, `len` and `limit`
/// being bounded by `ARRAY_MAX` = 2^31−1.
///
/// It stops **before** anything it cannot settle inside the range: [limit], a
/// maximal varint that would leave the buffer, or a malformed 10-byte varint.
/// The caller's byte-wise reader then re-reads those bytes and owns the
/// INCOMPLETE/INVALID verdict — one place decides, whichever surface got here.
///
/// Callers must guarantee `out.length >= limit`.
int _varintRun(
  Uint8List buf,
  ByteData bd,
  int len,
  int p,
  Int64List out,
  int i,
  int limit,
  bool signed,
) {
  while (i < limit && p + 10 <= len) {
    int raw;
    // One 64-bit load serves every length. The short-varint cases are derived
    // from that same word rather than from extra byte loads (a bounds-checked
    // `Uint8List` read costs ~8 instructions), and the all-continuation case is
    // tested first because it is the one that cannot be short-circuited.
    final x = bd.getUint64(p, Endian.little);
    final m = ~x & _contBits;
    if (m == 0) {
      // 9- or 10-byte varint. (Folding the two tail bytes into one
      // `ByteData.getUint16` measured very slightly *worse* than two
      // `Uint8List` loads, so they stay separate.)
      final b8 = buf[p + 8];
      raw = _unspread56(x) | ((b8 & 0x7F) << 56);
      if (b8 < 0x80) {
        p += 9;
      } else {
        final last = buf[p + 9];
        if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) break; // malformed
        raw |= (last & 0x7f) << 63;
        p += 10;
      }
    } else if ((m & 0x80) != 0) {
      raw = x & 0x7F; // 1 byte — skips the ~23-op un-spread
      p += 1;
    } else if ((m & 0x8000) != 0) {
      raw = (x & 0x7F) | (((x >>> 8) & 0x7F) << 7); // 2 bytes
      p += 2;
    } else {
      final nb = _termByte(m) + 1; // 3..8 bytes
      p += nb;
      raw = _unspread56(nb == 8 ? x : x & ((1 << (nb << 3)) - 1));
    }
    out[i++] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
  }
  return (i << 32) | p;
}

/// Whether any of `out[from..to)` falls outside [range]. See [ElemRange] for why
/// the unsigned arm also rejects a negative: Dart has no unsigned compare, and a
/// wire value above 2^63 is above every bound that can exist here.
bool _elemOutOfRange(
  Int64List out,
  int from,
  int to,
  bool signed,
  ElemRange range,
) {
  for (var i = from; i < to; i++) {
    final v = out[i];
    if (signed ? (v < range.min || v > range.max) : (v < 0 || v > range.max)) {
      return true;
    }
  }
  return false;
}

/// Whether the host stores typed-data elements in wire (little-endian) order —
/// true on every platform Dart targets. Where it holds, a fixlen array's wire
/// payload *is* the byte image of the `Float32List`/`Float64List` it decodes
/// into, which is what lets the readers below copy in bulk and lets the
/// streaming decoder stage the payload in the result list itself.
final bool _hostIsLittleEndian = Endian.host == Endian.little;

/// Fills [dst] with [count] fp32 elements from little-endian wire bytes in [src]
/// starting at [srcStart], preserving each element's raw 32-bit pattern
/// (CORELIB_PLAN §4.6 — a signaling NaN must not be quieted). On a little-endian
/// host (every platform Dart targets) this is a single bulk byte copy: bit-exact
/// *and* faster than a per-element float read. A big-endian host falls back to
/// endian-swapping element reads — which cannot preserve an sNaN, but no such
/// host exists in practice.
void _readFp32Array(Float32List dst, Uint8List src, int srcStart, int count) {
  if (_hostIsLittleEndian) {
    Uint8List.sublistView(dst).setRange(0, count * 4, src, srcStart);
  } else {
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 4);
    for (var i = 0; i < count; i++) {
      dst[i] = bd.getFloat32(i * 4, Endian.little);
    }
  }
}

/// Byte-swaps the first [count] elements of [dst] **in place**, where the wire's
/// little-endian bytes were written straight into a big-endian host's storage.
///
/// Reading and writing the same four bytes per element, so no staging buffer is
/// needed and nothing is allocated (CORELIB_PLAN §6.6). Never runs on any
/// platform Dart currently targets; it is the reason the fast path can be a
/// plain byte copy on every one of them.
void _swapFp32InPlace(Float32List dst, int count) {
  final bd = ByteData.sublistView(dst);
  for (var i = 0; i < count; i++) {
    dst[i] = bd.getFloat32(i * 4, Endian.little);
  }
}

/// The fp64 twin of [_swapFp32InPlace].
void _swapFp64InPlace(Float64List dst, int count) {
  final bd = ByteData.sublistView(dst);
  for (var i = 0; i < count; i++) {
    dst[i] = bd.getFloat64(i * 8, Endian.little);
  }
}

/// The fp64 twin of [_readFp32Array]: [count] 8-byte little-endian elements out
/// of [src] at [srcStart] into [dst], in bulk where the host layout already
/// matches the wire.
void _readFp64Array(Float64List dst, Uint8List src, int srcStart, int count) {
  if (_hostIsLittleEndian) {
    Uint8List.sublistView(dst).setRange(0, count * 8, src, srcStart);
  } else {
    final bd = ByteData.sublistView(src, srcStart, srcStart + count * 8);
    for (var i = 0; i < count; i++) {
      dst[i] = bd.getFloat64(i * 8, Endian.little);
    }
  }
}

/// Streaming SofaBuffers decoder (CORELIB_PLAN §5.2).
///
/// Feed arbitrarily small chunks via [feed]; the state machine suspends and
/// resumes at **any** byte boundary. Each [feed] (and the one-shot [decode])
/// returns the three-valued [DecodeStatus] describing the bytes consumed so far —
/// there is **no** finalize step, and `incomplete` is never auto-promoted to an
/// error.
///
/// Resuming anywhere is a guarantee, not a tariff: whatever a chunk carries
/// whole is taken whole — a varint out of it in one read ([_fastVarint]), a run
/// of integer array elements 64 bits at a time ([_bulkArrElems], the same reader
/// the one-shot surface uses), an opaque payload in one copy ([_bulkPayload]) —
/// and only a field genuinely straddling a boundary falls back to the per-byte
/// state machine. The only heap the hot path touches is a per-field carry buffer
/// for a `string`/`blob` payload; a float payload stages in a reusable slot.
class Decoder {
  Decoder(MessageVisitor root, {this.limits = const DecoderLimits()})
    : _vis = root {
    // Every piece of bounded working state this decoder will ever use is sized
    // here, at construction, and never again (CORELIB_PLAN §6.6).
    _fscratchData = ByteData.view(_fscratch.buffer);
  }

  final DecoderLimits limits;

  /// The visitor of the innermost open scope, or `null` while that scope is
  /// being skipped — held directly rather than re-read off the stack, because
  /// every field consults it several times.
  MessageVisitor? _vis;

  /// The *enclosing* scopes' visitors, innermost last; [_depth] is the number
  /// of open sequences. A plain visitor slot per level, not a wrapper object
  /// per scope — the scope carried nothing else, so a nested message allocates
  /// nothing per `sequence_start`.
  ///
  /// **Sized at construction, to its full extent** (CORELIB_PLAN §6.6): this is
  /// the parse stack the section names as permitted bounded working state, and
  /// the permission is conditional on the size coming from this document's
  /// [maxDepth] rather than from the wire. A list that grew as nesting deepened
  /// would allocate on a `feed` path, which is exactly what §6.6 forbids —
  /// "growing it afterwards is forbidden even where the ceiling it grows
  /// towards is correct".
  final List<MessageVisitor?> _enclosing = List<MessageVisitor?>.filled(
    maxDepth,
    null,
  );

  /// Number of open sequences — the number of valid entries in [_enclosing].
  int _depth = 0;

  int _state = _sHeader;
  bool _terminal = false; // an INVALID / limitExceeded outcome is sticky
  DecodeStatus _terminalStatus = DecodeStatus.invalid;

  // Skip-subtree depth: >0 means we are inside a skipped sequence (CORELIB_PLAN
  // §5.2 auto-skip). Independent of the frame stack, which still tracks open
  // sequences for boundary/COMPLETE detection.
  int _skipDepth = 0;

  // Varint accumulator (shared; only one varint is ever in progress).
  int _v = 0;
  int _vn = 0;

  // Current field context.
  int _fieldId = 0;
  bool _read = false; // materialize this field's value?

  // Fixlen payload context.
  int _fixSubtype = 0;
  int _payloadTotal = 0;
  int _payloadPos = 0;

  /// Where the payload in flight is being written — **the caller's
  /// destination** ([MessageVisitor.onBytesDest] / [MessageVisitor.onArrayDest],
  /// the latter as a byte view over its storage), or the decoder's own 8-byte
  /// landing zone for an `fp32`/`fp64` scalar, or `null` while a payload is
  /// being walked rather than read.
  ///
  /// There is no library-owned carry buffer: a payload split across chunks is
  /// joined here, in the caller's own storage, one piece per `feed`
  /// (CORELIB_PLAN §6.6.2).
  Uint8List? _payloadBuf;

  // Int-array context.
  int _arrType = 0; // WireType.arrayUnsigned or arraySigned
  int _arrCount = 0;
  int _arrIndex = 0;
  Int64List? _arrInts;
  // The declared element width for the array in flight, asked once at the count
  // word (see [MessageVisitor.onArrayElemBound]) and applied per element below,
  // so the per-element cost is two integer compares and no call.
  ElemRange? _arrElemRange;

  // Fixlen-array context: the caller's destination for the array in flight, and
  // the kind it was asked for.
  int _arrFixSubtype = 0;
  TypedData? _arrDest;
  ArrayKind _arrKind = ArrayKind.unsigned;

  /// Reusable 8-byte staging area for one `fp32`/`fp64` scalar payload, and its
  /// `ByteData` twin — the widest a float payload gets. A float field therefore
  /// allocates nothing: no per-field payload buffer and no per-field typed-data
  /// view (whose construction costs ~300 instructions under Dart AOT, several
  /// times a float read). Per **decoder**, not a shared static, so interleaved
  /// decoders cannot overwrite each other's half-arrived payload.
  ///
  /// Allocated **at construction**, not on first float: §6.6 permits bounded
  /// working state only where it is "sized to its full extent when the codec is
  /// constructed", and a `late final` initialiser runs on a `feed` path.
  final Uint8List _fscratch = Uint8List(8);
  late final ByteData _fscratchData;

  /// Feeds a chunk of raw bytes. Returns the outcome for everything consumed so
  /// far (CORELIB_PLAN §5.2).
  DecodeStatus feed(List<int> data) {
    if (_terminal) return _terminalStatus;
    try {
      return _feed(data);
    } on _Invalidated {
      _terminal = true;
      return _terminalStatus = DecodeStatus.invalid;
    } on _LimitExceeded {
      _terminal = true;
      return _terminalStatus = DecodeStatus.limitExceeded;
    }
  }

  /// The byte loop itself. Split out so it keeps a frame of its own: the
  /// `try` above must not sit around the loop the decoder's throughput is
  /// measured on.
  DecodeStatus _feed(List<int> data) {
    // Everything below reads bytes through a `Uint8List`: on that type AOT
    // compiles an element read down to a load, where `List<int>` indexing is an
    // interface call per byte, and only there can the bulk moves below reach
    // memcpy and a 64-bit varint load. A caller that hands over some other
    // `List<int>` gets the byte-wise reader instead — copying the chunk to get
    // the fast path would be a chunk copy the wire sizes, which §6.6 forbids
    // the codec outright.
    if (data is! Uint8List) return _feedSlow(data);
    final chunk = data;
    final n = chunk.length;
    // Built at most once per `feed`, and only for a chunk that actually carries
    // array elements: `ByteData.sublistView` is a §6.6.2 language-forced handle
    // — it addresses the caller's chunk, carries no message bytes of its own,
    // and costs the same whatever the chunk's length — but it is not free, so
    // it is hoisted out of the per-run call it used to sit in.
    ByteData? chunkData;
    var i = 0;
    while (i < n) {
      final state = _state;
      if (state >= _sFixPayload) {
        // Opaque payload: move the run this chunk holds in one go.
        if (n - i >= _bulkPayloadMin) {
          i += _bulkPayload(chunk, i, n);
          if (_payloadPos == _payloadTotal && !_payloadComplete()) {
            _terminal = true;
            return _terminalStatus;
          }
          if (i == n) break;
          continue;
        }
      } else if (_vn == 0) {
        // A varint state with nothing accumulated yet — so the chunk may hold
        // whole varints, and reading them as varints beats one state-machine
        // dispatch per byte by roughly an order of magnitude.
        if (state == _sArrElem) {
          chunkData ??= ByteData.sublistView(chunk);
          final took = _bulkArrElems(chunk, chunkData, i, n);
          if (took < 0) {
            _terminal = true;
            return _terminalStatus;
          }
          i += took;
          if (i == n) break;
        }
        final took = _fastVarint(chunk, i, n);
        if (took != 0) {
          i += took;
          final v = _v;
          _v = 0;
          if (!_onVarint(v)) {
            _terminal = true;
            return _terminalStatus;
          }
          continue;
        }
      }
      if (!_step(chunk[i])) {
        _terminal = true;
        return _terminalStatus;
      }
      i++;
    }
    return _boundaryStatus();
  }

  /// The byte-wise reader for a chunk that is not a `Uint8List`.
  ///
  /// One `_step` per byte, masked to 8 bits exactly as `Uint8List.fromList`
  /// would truncate — the same state machine, only without the bulk moves,
  /// which need the concrete type. It exists because the alternative is
  /// copying the chunk, and a copy the *wire* sizes is payload storage the
  /// codec may not take (CORELIB_PLAN §6.6). Callers wanting the fast path
  /// hand over a `Uint8List`.
  DecodeStatus _feedSlow(List<int> data) {
    final n = data.length;
    for (var i = 0; i < n; i++) {
      if (!_step(data[i] & 0xFF)) {
        _terminal = true;
        return _terminalStatus;
      }
    }
    return _boundaryStatus();
  }

  /// Reads one **whole** varint out of `data[from..end)` into [_v], and returns
  /// how many bytes it took — or 0, leaving [_v] untouched, when the chunk does
  /// not carry the whole of it or the encoding is malformed.
  ///
  /// Both refusals hand the bytes back to the byte-wise reader unread, which is
  /// where suspend-and-resume and the INVALID verdict live: this is a fast path,
  /// never a second opinion. Caller must have `_vn == 0` (nothing accumulated).
  int _fastVarint(Uint8List data, int from, int end) {
    var p = from;
    var v = 0;
    var shift = 0;
    while (p < end) {
      final b = data[p++];
      v |= (b & 0x7F) << shift;
      if (b < 0x80) {
        _v = v;
        return p - from;
      }
      shift += 7;
      if (shift == 63) {
        // The 10th byte may set only bit 63 and must terminate the varint.
        if (p >= end) return 0;
        final last = data[p++];
        if ((last & 0x80) != 0 || (last & 0x7F) > 0x01) return 0; // malformed
        _v = v | ((last & 0x7F) << 63);
        return p - from;
      }
    }
    return 0;
  }

  /// Takes the run of opaque payload bytes this chunk holds — a `string`,
  /// `blob`, `fp32`/`fp64` value or a fixlen array's elements — in **one move**
  /// instead of one state-machine dispatch per byte, and returns how many it
  /// took. Completion is the caller's to notice ([_payloadComplete]), the same
  /// as for the byte-wise [_stepPayload], so the value is delivered from one
  /// place however the payload arrived.
  int _bulkPayload(Uint8List data, int from, int end) {
    final want = _payloadTotal - _payloadPos;
    final have = end - from;
    final take = want < have ? want : have;
    if (take <= 0) return 0;
    if (_read) {
      _payloadBuf!.setRange(_payloadPos, _payloadPos + take, data, from);
    }
    _payloadPos += take;
    return take;
  }

  /// Takes the run of **whole array-element varints** this chunk can supply in
  /// one word-wise pass ([_varintRun]) instead of one state-machine dispatch per
  /// byte, and returns how many bytes it took (0 when there is nothing to take;
  /// −1 when an element turned out to be outside its declared width, which is
  /// terminal INVALID).
  ///
  /// Like [_bulkPayload] it stops one **element** short of the array's end: the
  /// last one goes through [_onArrElem], which owns the completion, so the
  /// array is delivered from exactly one place whether it arrived byte-by-byte
  /// or in a single chunk. It also declines a skipped array, whose elements are
  /// walked rather than materialized.
  int _bulkArrElems(Uint8List data, ByteData bd, int from, int end) {
    final out = _arrInts;
    final limit = _arrCount - 1;
    final first = _arrIndex;
    // The run reads a maximal varint at a time, so it needs that much room.
    // (`feed` only calls this with nothing accumulated, `_vn == 0`.)
    if (out == null || first >= limit || end - from < _bulkVarintMin) return 0;
    final signed = _arrType == WireType.arraySigned;
    final packed = _varintRun(data, bd, end, from, out, first, limit, signed);
    _arrIndex = packed >>> 32;
    // The declared width, applied AT the element (§7.1) — over the run rather
    // than one element at a time, which is the same `feed` call and so the same
    // reported outcome, INVALID still outranking a truncated tail (§5.2).
    final range = _arrElemRange;
    if (range != null &&
        _elemOutOfRange(out, first, _arrIndex, signed, range)) {
      _fail(DecodeStatus.invalid);
      return -1;
    }
    return (packed & 0xFFFFFFFF) - from;
  }

  DecodeStatus _boundaryStatus() {
    // COMPLETE only at a field boundary with no open sequence (CORELIB_PLAN
    // §5.2 framing invariant).
    if (_state == _sHeader && _vn == 0 && _depth == 0) {
      return DecodeStatus.complete;
    }
    return DecodeStatus.incomplete;
  }

  // Accumulate one byte into the varint. Returns 1=complete, 0=need more,
  // -1=overlong (>64 bits, INVALID).
  int _vfeed(int b) {
    if (_vn == 9) {
      // 10th byte: only bit 63 may be set, and it must terminate.
      if ((b & 0x80) != 0 || (b & 0x7F) > 0x01) return -1;
    } else if (_vn > 9) {
      return -1;
    }
    _v |= (b & 0x7F) << (7 * _vn);
    _vn++;
    return (b & 0x80) == 0 ? 1 : 0;
  }

  void _vreset() {
    _v = 0;
    _vn = 0;
  }

  bool _fail(DecodeStatus status) {
    _terminalStatus = status;
    return false; // propagate as terminal
  }

  // Process a single byte. Returns false on a terminal outcome.
  //
  // Every state but the two opaque payloads is waiting for a varint, so the
  // accumulate-and-test preamble lives here once rather than in each of them;
  // the state's actual decision is [_onVarint], which [feed]'s whole-varint fast
  // path reaches directly.
  bool _step(int b) {
    if (_state >= _sFixPayload) return _stepPayload(b);
    final r = _vfeed(b);
    if (r < 0) return _fail(DecodeStatus.invalid);
    if (r == 0) return true;
    final v = _v;
    _vreset();
    return _onVarint(v);
  }

  /// Acts on the varint [v] the current state was waiting for, however it was
  /// read — accumulated byte by byte by [_step] or lifted whole out of the chunk
  /// by [_fastVarint]. One place decides per state, so the two readers cannot
  /// drift apart.
  bool _onVarint(int v) {
    switch (_state) {
      case _sHeader:
        return _onHeader(v);
      case _sUValue:
        _state = _sHeader;
        if (_read) _vis!.onUnsigned(_fieldId, v);
        return true;
      case _sSValue:
        _state = _sHeader;
        if (_read) _vis!.onSigned(_fieldId, (v >>> 1) ^ -(v & 1));
        return true;
      case _sFixWord:
        return _onFixWord(v);
      case _sArrCount:
        return _onArrCount(v);
      case _sArrElem:
        return _onArrElem(v);
      case _sArrFixCount:
        return _onArrFixCount(v);
      case _sArrFixWord:
        return _onArrFixWord(v);
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _onHeader(int header) {
    final type = header & 0x7;
    final id = header >>> 3;
    if (id > idMax) return _fail(DecodeStatus.invalid); // id > ID_MAX (§6.2)
    _fieldId = id;

    switch (type) {
      case WireType.unsigned:
        _read = _decideRead(id, type);
        _state = _sUValue;
        return true;
      case WireType.signed:
        _read = _decideRead(id, type);
        _state = _sSValue;
        return true;
      case WireType.fixlen:
        _read = _decideRead(id, type);
        _state = _sFixWord;
        return true;
      case WireType.arrayUnsigned:
      case WireType.arraySigned:
        _read = _decideRead(id, type);
        _arrType = type;
        _state = _sArrCount;
        return true;
      case WireType.arrayFixlen:
        _read = _decideRead(id, type);
        _state = _sArrFixCount;
        return true;
      case WireType.sequenceStart:
        return _openSequence(id);
      case WireType.sequenceEnd:
        return _closeSequence();
    }
    return _fail(DecodeStatus.invalid);
  }

  // Decide read-vs-skip for a leaf field at header time.
  bool _decideRead(int id, int type) {
    if (_skipDepth > 0) return false;
    final v = _vis;
    if (v == null) return false;
    return v.shouldRead(id, type);
  }

  bool _openSequence(int id) {
    // Open count includes skipped sequences, so COMPLETE waits for them too.
    if (_depth >= maxDepth) {
      return _fail(DecodeStatus.invalid); // nesting past MAX_DEPTH
    }
    _enclosing[_depth++] = _vis;
    if (_skipDepth > 0) {
      _skipDepth++;
      _vis = null;
      return true;
    }
    final child = _vis!.onSequenceStart(id);
    if (child == null) _skipDepth = 1;
    _vis = child;
    return true;
  }

  bool _closeSequence() {
    if (_depth == 0) {
      return _fail(DecodeStatus.invalid); // sequence-end with no open sequence
    }
    final closed = _vis;
    final top = --_depth;
    _vis = _enclosing[top];
    _enclosing[top] = null; // do not keep a closed scope's visitor alive
    if (_skipDepth > 0) {
      _skipDepth--;
    } else {
      closed?.onSequenceEnd();
    }
    return true;
  }

  bool _onFixWord(int word) {
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (length > fixlenMax) return _fail(DecodeStatus.invalid);
    if (subtype >= 0x4) return _fail(DecodeStatus.invalid); // reserved
    if (subtype == FixlenType.fp32 && length != 4) {
      return _fail(DecodeStatus.invalid);
    }
    if (subtype == FixlenType.fp64 && length != 8) {
      return _fail(DecodeStatus.invalid);
    }
    // Header hand-off before truncation can be surfaced: a schema-invalid length
    // set here (via the override's sticky flag) dominates a short payload (§5.2).
    // It also comes BEFORE the receiver-side limit below, so a schema-bound
    // consumer learns of a breach the limit would otherwise short-circuit — the
    // limit is a statement about the receiver's capacity, never about the
    // field's validity (§6.2.1).
    _fixSubtype = subtype;
    _payloadTotal = length;
    _payloadPos = 0;
    _payloadBuf = null;
    if (_read) {
      _vis!.onFixlenHeader(_fieldId, subtype, length);
      // Receiver-side limit (well-formed bytes → limitExceeded, not INVALID) —
      // unless the schema bounds this field, where the schema bound decides.
      final verdict = _fixlenLenVerdict(
        _vis!,
        limits,
        _fieldId,
        subtype,
        length,
      );
      if (verdict != null) return _fail(verdict);
      // A float payload stages in the reusable per-decoder landing zone (4/8
      // bytes, both validated above). A `string`/`blob` goes straight into the
      // destination the caller hands over — asked for here, at the length word,
      // before a payload byte is consumed (§6.6.3). Declining it turns the
      // field into a walk, exactly as `shouldRead` returning false would have.
      if (subtype >= FixlenType.string) {
        final dest = _bytesDest(_vis!, _fieldId, subtype, length);
        if (dest == null) {
          _read = false;
        } else {
          _payloadBuf = dest;
        }
      } else {
        _payloadBuf = _fscratch;
      }
    }
    _state = _sFixPayload;
    return length == 0 ? _payloadComplete() : true;
  }

  /// One opaque payload byte — a `string`/`blob`/float value or a fixlen array
  /// element — into the staging area, and the payload's completion when it is
  /// the last one.
  bool _stepPayload(int b) {
    if (_read) _payloadBuf![_payloadPos] = b;
    _payloadPos++;
    if (_payloadPos < _payloadTotal) return true;
    return _payloadComplete();
  }

  /// Delivers a payload that has just become whole, however its bytes arrived —
  /// one byte at a time through [_stepPayload] or in a single move through
  /// [_bulkPayload] — and reopens the field boundary. The single place a fixlen
  /// value or a fixlen array reaches the visitor.
  bool _payloadComplete() {
    if (_state == _sFixPayload) {
      if (!_emitFixlen()) return false;
    } else if (_read) {
      _emitFixArray();
    }
    _state = _sHeader;
    return true;
  }

  bool _emitFixlen() {
    if (!_read) return true;
    switch (_fixSubtype) {
      case FixlenType.fp32:
        {
          final view = _fscratchData;
          final v = view.getFloat32(0, Endian.little);
          // Non-NaN widens to a double and back losslessly (hot path). A NaN can
          // carry a payload/signaling bit the double would quiet, so re-read the
          // raw wire bits and deliver those (§4.6: never normalize).
          if (v.isNaN) {
            _vis!.onFp32Bits(_fieldId, view.getUint32(0, Endian.little));
          } else {
            _vis!.onFp32(_fieldId, v);
          }
          return true;
        }
      case FixlenType.fp64:
        _vis!.onFp64(_fieldId, _fscratchData.getFloat64(0, Endian.little));
        return true;
      case FixlenType.string:
      case FixlenType.blob:
        // The payload is complete in the caller's own destination; validation
        // happens there, never here — this point is only reached for a field
        // being materialized (CORELIB_PLAN §6.4). The default string hook
        // validates strictly (no U+FFFD substitution) and only then decodes the
        // now-known-valid bytes.
        if (!_deliverPayload(
          _vis!,
          _fieldId,
          _fixSubtype,
          _payloadBuf ?? _noBytes,
          _payloadTotal,
        )) {
          return _fail(DecodeStatus.invalid);
        }
        return true;
    }
    return _fail(DecodeStatus.invalid);
  }

  bool _onArrCount(int count) {
    // ARRAY_MAX is an *unsigned* ceiling on a full u64 count word (§6.2, §4.8),
    // and Dart has no unsigned compare: a count with bit 63 set is a negative
    // int here, so `> arrayMax` alone would let it through. Rejected before any
    // allocation, any `count * length` and any cursor move (§7.2 item 5).
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    // Header hand-off before any element (and thus before truncation) — an
    // over-count set INVALID here dominates a short element tail (§5.2). An
    // integer array carries no second word, so this is already the point at
    // which the element kind is fully known (§4.8). It also precedes the
    // receiver-side limit, which must not short-circuit a schema bound (§6.2.1).
    if (_read) {
      final kind = _arrType == WireType.arraySigned
          ? ArrayKind.signed
          : ArrayKind.unsigned;
      _arrKind = kind;
      _vis!.onArrayBegin(_fieldId, kind, count);
      final verdict = _arrayCountVerdict(_vis!, limits, _fieldId, kind, count);
      if (verdict != null) return _fail(verdict);
      // Asked once, here, for the same reason onArrayBegin fires here: this is
      // where the field is fully identified and no element has been consumed.
      _arrElemRange = _vis!.onArrayElemBound(_fieldId, kind);
      // ... and the destination, for the same reason again: the elements are
      // decoded straight into the caller's storage (§6.6.3), so it has to be in
      // hand before the first one. Declining turns the field into a walk.
      final dest = _arrayDest(_vis!, _fieldId, kind, count);
      if (dest == null) {
        _read = false;
        _arrInts = null;
      } else {
        _arrInts = dest as Int64List;
      }
    } else {
      _arrElemRange = null;
      _arrInts = null;
    }
    _arrCount = count;
    _arrIndex = 0;
    if (count == 0) {
      if (_read) _emitIntArray();
      _state = _sHeader;
      return true;
    }
    _state = _sArrElem;
    return true;
  }

  bool _onArrElem(int raw) {
    if (_read) {
      final signed = _arrType == WireType.arraySigned;
      final v = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
      // The declared width, applied AT the element (§7.1). The whole-array
      // callback below is too late for an array that never completes, and §5.2
      // makes this element's INVALID outrank that truncation.
      final r = _arrElemRange;
      if (r != null &&
          (signed ? (v < r.min || v > r.max) : (v < 0 || v > r.max))) {
        return _fail(DecodeStatus.invalid);
      }
      _arrInts![_arrIndex] = v;
    }
    _arrIndex++;
    if (_arrIndex < _arrCount) return true;
    if (_read) _emitIntArray();
    _state = _sHeader;
    return true;
  }

  void _emitIntArray() {
    _vis!.onArrayDone(_fieldId, _arrKind, _arrInts!, _arrCount);
  }

  bool _onArrFixCount(int count) {
    // Unsigned ceiling — see [_onArrCount]. This one also guards the
    // `_arrCount * length` below, which a bit-63 count would wrap.
    if (count < 0 || count > arrayMax) return _fail(DecodeStatus.invalid);
    // NO header hand-off here: for a fixlen array the element subtype lives in
    // the *next* word, and §4.8 requires it to be decided before the field is
    // offered (see [MessageVisitor.onArrayBegin]). The hook fires in
    // [_onArrFixWord], and so does the receiver-side count limit — deciding
    // whether the SCHEMA bounds this count needs the element kind, for the
    // reason the hook does (a mismatched subtype is another field's shape,
    // §7.3). Only the format ceiling above belongs to the bare count word; the
    // limit still lands before the payload allocation it prevents (§6.2.1).
    _arrCount = count;
    _arrIndex = 0;
    _state = _sArrFixWord;
    return true;
  }

  bool _onArrFixWord(int word) {
    final length = word >>> 3;
    final subtype = word & 0x7;
    // Only fp32/fp64 are legal in a fixlen array (CORELIB_PLAN §4.8).
    if (subtype == FixlenType.fp32) {
      if (length != 4) return _fail(DecodeStatus.invalid);
    } else if (subtype == FixlenType.fp64) {
      if (length != 8) return _fail(DecodeStatus.invalid);
    } else {
      return _fail(DecodeStatus.invalid); // string/blob/reserved not allowed
    }
    // The subtype is now known and legal, so this is the §4.8 point at which the
    // field can be offered: the hook carries the real element kind, and still
    // fires before the payload (thus before truncation), so an over-count set
    // INVALID here dominates a short tail (§5.2). It also fires for count == 0.
    if (_read) {
      final kind = subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64;
      _arrKind = kind;
      _vis!.onArrayBegin(_fieldId, kind, _arrCount);
      final verdict = _arrayCountVerdict(
        _vis!,
        limits,
        _fieldId,
        kind,
        _arrCount,
      );
      if (verdict != null) return _fail(verdict);
    }
    _arrFixSubtype = subtype;
    _payloadTotal = _arrCount * length;
    _payloadPos = 0;
    if (_read) {
      // NO staging buffer, and no copy at the end: the arriving wire bytes are
      // written straight into the **caller's** destination, because a fixlen
      // array's payload already is that list's little-endian byte image. Peak
      // memory is the caller's list and nothing else, and [_emitFixArray] has
      // nothing left to move — the streaming path costs what the one-shot path
      // costs. A (hypothetical) big-endian host writes the same bytes and swaps
      // them in place once the payload is whole, which still allocates nothing.
      final dest = _arrayDest(_vis!, _fieldId, _arrKind, _arrCount);
      if (dest == null) {
        _read = false;
        _arrDest = null;
        _payloadBuf = null;
      } else {
        _arrDest = dest;
        _payloadBuf = Uint8List.sublistView(dest);
      }
    } else {
      _arrDest = null;
      _payloadBuf = null;
    }
    _state = _sArrFixPayload;
    return _payloadTotal == 0 ? _payloadComplete() : true;
  }

  void _emitFixArray() {
    // The elements are already in the caller's list, bit-exact; only a
    // big-endian host has anything left to do, and it does it in place.
    final out = _arrDest!;
    if (!_hostIsLittleEndian) {
      if (_arrFixSubtype == FixlenType.fp32) {
        _swapFp32InPlace(out as Float32List, _arrCount);
      } else {
        _swapFp64InPlace(out as Float64List, _arrCount);
      }
    }
    _vis!.onArrayDone(_fieldId, _arrKind, out, _arrCount);
  }

  /// One-shot decode of a whole, already-in-memory [bytes] buffer into
  /// [visitor] (CORELIB_PLAN §6.1 convenience). This is the common case
  /// (`deserialize`, any message that fits in memory), so it runs the fast
  /// **contiguous** path — advancing an index over the buffer rather than the
  /// per-byte streaming state machine — for a large decode speed-up. It
  /// produces byte-identical visitor calls and the same [DecodeStatus] as
  /// feeding the same bytes through [feed]; use a streaming [Decoder] + [feed]
  /// when the input arrives in chunks.
  static DecodeStatus decode(
    List<int> bytes,
    MessageVisitor visitor, {
    DecoderLimits limits = const DecoderLimits(),
  }) {
    final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _ContiguousDecoder(buf, limits).run(visitor);
  }
}

/// Fast one-shot decoder for a fully-contiguous buffer. Advances an index over
/// the bytes (the protobuf-style "advance a pointer over a contiguous buffer"),
/// with no per-byte state machine and no `Decoder`/frame allocation. Recursive
/// descent over sequences. Semantics — decode outcomes, INVALID-over-INCOMPLETE
/// precedence, skip-without-validation, receiver limits — match [Decoder.feed]
/// exactly (both are covered by the same conformance vectors).
class _ContiguousDecoder {
  _ContiguousDecoder(this._buf, this._limits) : _len = _buf.length;

  final Uint8List _buf;
  final DecoderLimits _limits;
  final int _len;
  int _pos = 0;

  ByteData? _bdCache;

  /// Wide view of [_buf], created **on first use**.
  ///
  /// Constructing a typed-data view costs ~300 instructions under Dart AOT —
  /// more than decoding a whole small message — so it is confined to the places
  /// that amortize it over many elements (array payloads, §4.7–4.8) and created
  /// only if such a field actually turns up. Scalar reads never trigger it: the
  /// varint reader is a byte loop and one-off floats go through [_scratchData].
  @pragma('vm:prefer-inline')
  ByteData get _bd =>
      _bdCache ??= ByteData.view(_buf.buffer, _buf.offsetInBytes, _len);
  // `complete` doubles as the "still ok" sentinel while walking.
  DecodeStatus _st = DecodeStatus.complete;

  DecodeStatus run(MessageVisitor root) {
    try {
      _walk(root, 0);
    } on _Invalidated {
      return DecodeStatus.invalid;
    } on _LimitExceeded {
      return DecodeStatus.limitExceeded;
    }
    return _st;
  }

  // Reads an unsigned LEB128 varint. On end-of-buffer sets INCOMPLETE; on an
  // overlong (>64-bit) varint sets INVALID. Value valid only when `_st` stays
  // `complete`.
  //
  // Three tiers, cheapest first: a single-byte varint (the overwhelmingly common
  // case — field headers, small ids, counts, small values), then the word-wise
  // reader when a maximal varint is guaranteed in bounds, then the byte loop for
  // the last few bytes of the buffer.
  @pragma('vm:prefer-inline')
  int _uvarint() {
    final p = _pos;
    if (p < _len) {
      final b = _buf[p];
      if (b < 0x80) {
        _pos = p + 1;
        return b;
      }
      // Hand the byte on rather than making the continuation re-read it.
      return _uvarintMulti(b);
    }
    _st = DecodeStatus.incomplete;
    return 0;
  }

  /// Continuation of a varint whose first byte [b0] is already in hand (and had
  /// its continuation bit set), byte at a time.
  ///
  /// Deliberately *not* the word-wise reader: that needs the [_bd] view, whose
  /// ~300-instruction construction only pays off when amortized over many
  /// elements. A scalar field carries one varint, so the byte loop wins — the
  /// word-wise reader lives in the array element loop ([_intArray]) instead.
  /// This is also the path that reports INCOMPLETE.
  int _uvarintMulti(int b0) {
    final buf = _buf;
    final len = _len;
    var p = _pos + 1; // [b0] is the byte at _pos
    var v = b0 & 0x7F;
    var shift = 7;
    while (p < len) {
      final b = buf[p++];
      v |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        _pos = p;
        return v;
      }
      shift += 7;
      if (shift == 63) {
        // The 10th byte may set only bit 63 and must terminate the varint.
        if (p >= len) break;
        final last = buf[p++];
        _pos = p;
        if ((last & 0x80) != 0 || (last & 0x7f) > 0x01) {
          _st = DecodeStatus.invalid;
          return 0;
        }
        return v | ((last & 0x7f) << 63);
      }
    }
    _pos = p;
    _st = DecodeStatus.incomplete;
    return 0;
  }

  void _walk(MessageVisitor? vis, int depth) {
    while (_pos < _len) {
      final header = _uvarint();
      if (_st != DecodeStatus.complete) return;
      final type = header & 0x7;
      final id = header >>> 3;
      if (id > idMax) {
        _st = DecodeStatus.invalid; // id > ID_MAX (§6.2)
        return;
      }
      switch (type) {
        case WireType.unsigned:
          final readU = vis != null && vis.shouldRead(id, type);
          final val = _uvarint();
          if (_st != DecodeStatus.complete) return;
          if (readU) vis.onUnsigned(id, val);
          break;
        case WireType.signed:
          final readS = vis != null && vis.shouldRead(id, type);
          final raw = _uvarint();
          if (_st != DecodeStatus.complete) return;
          if (readS) vis.onSigned(id, (raw >>> 1) ^ -(raw & 1));
          break;
        case WireType.fixlen:
          if (!_fixlen(vis, id, vis != null && vis.shouldRead(id, type))) {
            return;
          }
          break;
        case WireType.arrayUnsigned:
        case WireType.arraySigned:
          if (!_intArray(
            vis,
            id,
            type,
            vis != null && vis.shouldRead(id, type),
          )) {
            return;
          }
          break;
        case WireType.arrayFixlen:
          if (!_fixArray(vis, id, vis != null && vis.shouldRead(id, type))) {
            return;
          }
          break;
        case WireType.sequenceStart:
          if (depth >= maxDepth) {
            _st = DecodeStatus.invalid;
            return;
          }
          final child = vis?.onSequenceStart(id);
          _walk(child, depth + 1);
          if (_st != DecodeStatus.complete) return;
          break;
        case WireType.sequenceEnd:
          if (depth == 0) {
            _st = DecodeStatus.invalid; // unbalanced end, no open sequence
            return;
          }
          vis?.onSequenceEnd();
          return; // hand control back to the parent scope
      }
    }
    if (depth != 0) _st = DecodeStatus.incomplete; // sequence never closed
  }

  bool _fixlen(MessageVisitor? vis, int id, bool read) {
    final word = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (length > fixlenMax) return _bad(DecodeStatus.invalid);
    if (subtype >= 0x4) return _bad(DecodeStatus.invalid);
    if (subtype == FixlenType.fp32 && length != 4) {
      return _bad(DecodeStatus.invalid);
    }
    if (subtype == FixlenType.fp64 && length != 8) {
      return _bad(DecodeStatus.invalid);
    }
    // Header hand-off before the truncation check, so a schema-invalid length
    // (flagged in the override) dominates a short payload (§5.2) — and before
    // the receiver-side limit, which must not short-circuit it (§6.2.1). See
    // [_fixlenLenVerdict] for the limit-vs-schema-bound split.
    // The destination is asked for at the same point the streaming surface asks
    // — at the length word, before the payload — so the two surfaces make the
    // same calls in the same order on the same bytes (§6.7.1). `subtype >=
    // string` is the pair that carries one: fp32/fp64 land in the shared 8-byte
    // scratch.
    Uint8List? dest;
    if (read) {
      vis!.onFixlenHeader(id, subtype, length);
      final verdict = _fixlenLenVerdict(vis, _limits, id, subtype, length);
      if (verdict != null) return _bad(verdict);
      if (subtype >= FixlenType.string) {
        // A payload longer than what is left in the buffer has been refuted by
        // the input: the field can never be delivered, so the caller is not
        // asked for storage it could never be given. Same deduction as
        // [_intArray]'s, and the reason the one-shot surface never sizes
        // anything from a count or length the message cannot back.
        if (_pos + length > _len) return _bad(DecodeStatus.incomplete);
        dest = _bytesDest(vis, id, subtype, length);
        if (dest == null) read = false;
      }
    }
    if (_pos + length > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += length;
    if (read) {
      switch (subtype) {
        case FixlenType.fp32:
          {
            // Stage the 4 payload bytes rather than building a view (see
            // [_scratchData]).
            final buf = _buf;
            final s = _scratchBytes;
            s[0] = buf[start];
            s[1] = buf[start + 1];
            s[2] = buf[start + 2];
            s[3] = buf[start + 3];
            final v = _scratchData.getFloat32(0, Endian.little);
            // See _emitFixlen: NaN goes out as raw bits so a signaling NaN's
            // is-quiet bit is not set by widening to a double (§4.6).
            if (v.isNaN) {
              vis!.onFp32Bits(id, _scratchData.getUint32(0, Endian.little));
            } else {
              vis!.onFp32(id, v);
            }
            break;
          }
        case FixlenType.fp64:
          // `setRange` between two `Uint8List`s hits a bulk copy and measured
          // cheaper than eight indexed stores at this width.
          _scratchBytes.setRange(0, 8, _buf, start);
          vis!.onFp64(id, _scratchData.getFloat64(0, Endian.little));
          break;
        case FixlenType.string:
        case FixlenType.blob:
          // The payload is **copied** into the caller's destination, exactly as
          // the streaming surface copies it: §6.7.1 gives the one-shot path no
          // view exemption — "decode(buffer) copies too", so that a port's
          // memory behaviour cannot depend on which entry point was used. See
          // _emitFixlen: the destination validates, the decoder does not.
          final d = dest!;
          if (length != 0) d.setRange(0, length, _buf, start);
          if (!_deliverPayload(vis!, id, subtype, d, length)) {
            return _bad(DecodeStatus.invalid);
          }
          break;
      }
    }
    return true;
  }

  bool _intArray(MessageVisitor? vis, int id, int type, bool read) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling: the count word is a full u64, so a count with bit 63
    // set lands as a negative Dart int and `> arrayMax` alone misses it — the
    // element loop would then either allocate an impossible `Int64List` or, on
    // the skip path, run zero times and accept a bogus empty array (§6.2, §4.8).
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    final signed = type == WireType.arraySigned;
    // Header hand-off before the element loop (before truncation) — over-count
    // flagged here dominates a short tail (§5.2). An integer array carries no
    // second word, so the element kind is already fully known here (§4.8). The
    // receiver-side limit comes after the hook and yields to a schema bound
    // (§6.2.1) — see [_arrayCountVerdict].
    ElemRange? range;
    final kind = signed ? ArrayKind.signed : ArrayKind.unsigned;
    if (read) {
      vis!.onArrayBegin(id, kind, count);
      final verdict = _arrayCountVerdict(vis, _limits, id, kind, count);
      if (verdict != null) return _bad(verdict);
      range = vis.onArrayElemBound(id, kind);
    }
    if (!read) {
      // Skipping: walk the element varints without materializing anything.
      for (var i = 0; i < count; i++) {
        _uvarint();
        if (_st != DecodeStatus.complete) return false;
      }
      return true;
    }
    // A count above the bytes that remain has already been refuted by the
    // input: every element costs at least one varint byte, so the array is
    // bound for INCOMPLETE and will never be delivered. The caller is not asked
    // for a destination it could never be given — a 6-byte message claiming
    // ARRAY_MAX elements would otherwise have anything sized from that count
    // (§7.2 item 5: a well-defined outcome, never a crash). The prefix is still
    // walked, because an element outside its declared width keeps outranking
    // the truncation (§5.2) instead of being lost to an early bail-out.
    //
    // The streaming surface cannot make this deduction — it does not know what
    // has not arrived yet — which is exactly the gap §6.2.1's receiver caps
    // cover, and they are checked above on both surfaces alike.
    final avail = _len - _pos;
    if (count > avail) {
      for (var k = 0; k < count; k++) {
        final raw = _uvarint();
        if (_st != DecodeStatus.complete) return false;
        final v = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
        if (range != null &&
            (signed
                ? (v < range.min || v > range.max)
                : (v < 0 || v > range.max))) {
          return _bad(DecodeStatus.invalid);
        }
      }
      return _bad(DecodeStatus.incomplete); // unreachable: count > avail
    }
    final dest = _arrayDest(vis!, id, kind, count);
    if (dest == null) {
      // Declined: walk the elements and deliver nothing.
      for (var k = 0; k < count; k++) {
        _uvarint();
        if (_st != DecodeStatus.complete) return false;
      }
      return true;
    }
    final out = dest as Int64List;
    var i = 0;
    // Word-wise element run — the same [_varintRun] the streaming surface uses,
    // so both cost the same per element. Entered only when a maximal varint is
    // in bounds, which is also the condition under which building the [_bd] view
    // pays for itself: a short array near the end of the buffer skips it
    // entirely and takes the byte-wise reader below.
    if (_pos + 10 <= _len) {
      final packed = _varintRun(_buf, _bd, _len, _pos, out, 0, count, signed);
      i = packed >>> 32;
      _pos = packed & 0xFFFFFFFF;
    }
    // Tail: the last elements, where a 64-bit load would overrun the buffer —
    // and the malformed 10-byte varint the run declines to settle. Also the path
    // that reports INCOMPLETE on a short element run.
    for (; i < count; i++) {
      final raw = _uvarint();
      if (_st != DecodeStatus.complete) {
        // The array does not complete, so neither whole-array callback below
        // fires and the consumer's own width guard never runs. The elements
        // already decoded are on the wire all the same, and §5.2 makes one
        // outside its declared width outrank this truncation (generator#267).
        // Checked HERE rather than in the loops above so the word-wise hot path
        // stays a pure decode: the prefix is walked only when the array fails.
        if (range != null && _elemOutOfRange(out, 0, i, signed, range)) {
          return _bad(DecodeStatus.invalid);
        }
        return false;
      }
      out[i] = signed ? (raw >>> 1) ^ -(raw & 1) : raw;
    }
    // ... and the same sweep once the array HAS arrived. An element outside its
    // declared width is INVALID wherever it sits (§7.1), and the whole-array
    // callbacks below return `void`, so a visitor that answered
    // [MessageVisitor.onArrayElemBound] has no channel left to reject through:
    // leaving this case to them contradicted the hook's own contract ("the
    // decoder then applies the range as the elements go past") and made this
    // surface disagree with [Decoder.feed], which checks at every element (#38).
    // Still off the hot path in the sense that matters: one pass over an
    // in-cache `Int64List`, and only for a field that declares a narrowed width.
    if (range != null && _elemOutOfRange(out, 0, count, signed, range)) {
      return _bad(DecodeStatus.invalid);
    }
    vis.onArrayDone(id, kind, out, count);
    return true;
  }

  bool _fixArray(MessageVisitor? vis, int id, bool read) {
    final count = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    // Unsigned ceiling — see [_intArray]. It also keeps `count * length` below
    // from wrapping, which would move `_pos` backwards.
    if (count < 0 || count > arrayMax) return _bad(DecodeStatus.invalid);
    // NO header hand-off here: §4.8 has the element subtype decided first, so the
    // hook waits for the word below (see [MessageVisitor.onArrayBegin]). EOF
    // between the two words is therefore INCOMPLETE, not INVALID. The
    // receiver-side count limit waits with it — whether the SCHEMA bounds this
    // count is a question about the element kind (§7.3) — and still lands before
    // the payload allocation it prevents.
    final word = _uvarint();
    if (_st != DecodeStatus.complete) return false;
    final length = word >>> 3;
    final subtype = word & 0x7;
    if (subtype == FixlenType.fp32) {
      if (length != 4) return _bad(DecodeStatus.invalid);
    } else if (subtype == FixlenType.fp64) {
      if (length != 8) return _bad(DecodeStatus.invalid);
    } else {
      return _bad(DecodeStatus.invalid);
    }
    // Subtype known and legal: offer the field now, carrying the real element
    // kind, still before the payload (thus before truncation) — over-count
    // flagged here dominates a short tail (§5.2). Fires for count == 0 too.
    final kind = subtype == FixlenType.fp32 ? ArrayKind.fp32 : ArrayKind.fp64;
    TypedData? dest;
    if (read) {
      vis!.onArrayBegin(id, kind, count);
      final verdict = _arrayCountVerdict(vis, _limits, id, kind, count);
      if (verdict != null) return _bad(verdict);
      // The payload is fixed-width, so a buffer too short for `count * length`
      // has refuted the count outright: nothing is asked for and nothing is
      // sized from it. Same deduction as [_intArray]'s, exact here.
      if (_pos + count * length <= _len) {
        dest = _arrayDest(vis, id, kind, count);
        if (dest == null) read = false;
      }
    }
    final total = count * length;
    if (_pos + total > _len) return _bad(DecodeStatus.incomplete);
    final start = _pos;
    _pos += total;
    if (read) {
      if (subtype == FixlenType.fp32) {
        final o = dest as Float32List;
        _readFp32Array(o, _buf, start, count);
        vis!.onArrayDone(id, kind, o, count);
      } else {
        final o = dest as Float64List;
        _readFp64Array(o, _buf, start, count);
        vis!.onArrayDone(id, kind, o, count);
      }
    }
    return true;
  }

  bool _bad(DecodeStatus status) {
    _st = status;
    return false;
  }
}
