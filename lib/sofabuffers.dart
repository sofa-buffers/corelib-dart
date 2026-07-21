/// SofaBuffers — Structured Objects For Anyone.
///
/// A compact, self-describing, fully **streamable** binary serialization format.
/// This is `corelib-dart`, the high-speed Dart core library. It is byte-for-byte
/// compatible with every other SofaBuffers port and validated against the shared
/// conformance vectors.
///
/// The public surface uses the fixed `sofab` namespace (CORELIB_PLAN §6). Import
/// it aliased:
///
/// ```dart
/// import 'package:sofabuffers/sofabuffers.dart' as sofab;
///
/// // Encode
/// final bytes = sofab.Encoder.encodeToBytes((e) {
///   e.writeUnsigned(1, 0xDEADBEEF);
///   e.writeString(5, 'sofab');
/// });
///
/// // Decode
/// final v = MyVisitor();
/// final status = sofab.Decoder.decode(bytes, v);
/// assert(status == sofab.DecodeStatus.complete);
/// ```
///
/// See the `Encoder` (streaming out) and `Decoder` (push-feed / pull-read in)
/// classes for the full streaming API, and the `example/` directory for the
/// generated-object pattern built on top of these primitives.
library sofab;

export 'src/wire.dart'
    show
        apiVersion,
        idMax,
        fixlenMax,
        arrayMax,
        maxDepth,
        WireType,
        FixlenType,
        DecodeStatus,
        SofabError,
        SofabException;
export 'src/utf8.dart' show utf8Valid, encodeUtf8Strict;
export 'src/encoder.dart' show Encoder, FlushCallback;
export 'src/decoder.dart' show Decoder, MessageVisitor, DecoderLimits;
