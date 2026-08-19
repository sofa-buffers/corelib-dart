import 'dart:typed_data';

import 'decoder.dart';

// The visitor base a schema-bound (generated) consumer starts from. It carries
// no schema: what it does is the same for every message, so it belongs here
// rather than being emitted, comment and all, into every generated file.

/// A [MessageVisitor] whose defaults are the ones a **schema-bound consumer**
/// needs: an id this scope does not declare is *skipped*, not inspected.
///
/// The two defaults it flips both matter, and both flip for the same reason —
/// [MessageVisitor]'s own defaults are written for a hand-written visitor,
/// which wants to see everything, while a generated scope knows exactly which
/// ids it binds and must leave the rest untouched:
///
/// * [onStringBytes] — the base class default *validates* the payload as UTF-8
///   and fails the decode if it is not (this port is always strict, CORELIB_PLAN
///   §6.4). Whether a string may be inspected at all is a schema question:
///   MESSAGE_SPEC §7.3 makes an id the scope does not declare a **skipped**
///   field, and §6.4 says skipped payloads are never validated. So the default
///   here returns without validating and without flagging INVALID. A scope with
///   string destinations overrides this, resolves the destination for `id`
///   first, and calls `decodeUtf8Strict` only inside a matched arm — falling
///   through to this same no-op for every id it does not match.
/// * [onSequenceStart] — the base class default returns `this`, i.e. descend.
///   Whether a sequence at this position is one the schema binds is again a
///   schema question, so the default here returns `null`: skip the
///   sub-sequence **whole**, children included. A scope that declares sequences
///   overrides this and falls through to the same `null` for every id it does
///   not match — which is what keeps a sequence arriving at a leaf element
///   position from binding its child as that element, since a leaf collector
///   declares no sequences and inherits the skip.
///
/// Every other hook keeps its [MessageVisitor] default. Reporting a rejected
/// payload is the subclass's own business: the callbacks return `void`, so a
/// schema violation seen here is recorded on a sticky INVALID flag the consumer
/// carries and converted to a terminal `DecodeStatus.invalid` after the decoder
/// returns.
abstract class VisitorBase extends MessageVisitor {
  @override
  void onStringBytes(int id, Uint8List bytes) {}

  @override
  MessageVisitor? onSequenceStart(int id) => null;
}
