/// Chooses which HLS delivery strategy to request from the server.
///
/// Extracted as a free function so it can be unit-tested without a widget
/// tree, following the same pattern as `shouldOfferResume` in
/// [resume_plan.dart] and the helpers in [playback_error.dart].
library;

/// Picks the HLS strategy to request from the streaming-session mutation,
/// given the priority-ordered strategy values from `streamingCandidates`
/// (best first).
///
/// [strategyValues] is the plain-string form of each candidate's `strategy`
/// (`candidate.strategy.toJson()`), in the order the server returned them.
///
/// A leading `HLS_COPY` is the server's `:needs_transcoding` verdict.
/// `Mydia.Streaming.Candidates.build_streaming_candidates/2` only ever
/// reaches for `HLS_COPY` ahead of `TRANSCODE` from that branch, where every
/// such entry still carries the file's original video codec — `HLS_COPY`
/// repackages a stream without re-encoding it, so it can never turn an
/// incompatible codec into a compatible one. Requesting it here would hand
/// an old server's leading `HLS_COPY` candidate straight to the streaming
/// session and reproduce the "Could not open codec." failure this function
/// exists to avoid: a Fire HD 10, whose HEVC decoder is Main 8-bit only,
/// choking on an HEVC Main 10 source it was told to stream untouched.
///
/// This holds against both an old server, which always leads
/// `:needs_transcoding` with `HLS_COPY`, and one carrying the #564 fix,
/// which omits `HLS_COPY` from that branch entirely once the client's
/// declared codecs reject the source. Either way, an `HLS_COPY` that
/// survives to the front of the list is never one this function may
/// request.
///
/// A later `HLS_COPY` — behind a leading `DIRECT_PLAY` or `REMUX` — is a
/// different situation: the `:needs_remux` branch leads with `REMUX` and
/// lists `HLS_COPY` second (`[REMUX, HLS_COPY, TRANSCODE]`), and in that
/// branch the codecs are already known compatible; only the container
/// isn't. That `HLS_COPY` is genuine and safe to request.
///
/// Falls back to `TRANSCODE` — the one strategy that is always safe to ask
/// for — whenever no qualifying `HLS_COPY` entry exists.
String pickHlsStrategy(List<String> strategyValues) {
  final leadsWithHlsCopy =
      strategyValues.isNotEmpty && strategyValues.first == 'HLS_COPY';

  if (!leadsWithHlsCopy && strategyValues.contains('HLS_COPY')) {
    return 'HLS_COPY';
  }

  return 'TRANSCODE';
}
