/// The cast seam for a third-party item, built on its playback session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cast/cast_backend.dart';
import '../../../../core/cast/cast_content.dart';
import '../../../../core/cast/cast_route_resolver.dart';
import '../../../../core/cast/receiver_profile.dart';
import '../../../../core/cast/source_cast_binding.dart';
import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/periodic_progress_reporter.dart';
import '../../../../core/sources/sources_providers.dart';
import '../../../../domain/models/cast_device.dart';
import '../../../../domain/models/quality_rung.dart';
import '../../../../domain/sources/source_error.dart';
import 'mydia_source_playback_session.dart';
import 'playback_session_types.dart';
import 'source_playback_session.dart';
import 'source_playback_sessions.dart';

class SessionSourceCastBinding implements SourceCastBinding {
  SessionSourceCastBinding(this._session);

  final SourcePlaybackSession _session;

  /// The resolver that started each server session, so [endServerSession]
  /// ends it on the same one.
  final _resolvers = <String, StreamResolver>{};

  @override
  Future<CastRoute> resolve({
    required CastProtocolKind protocol,
    required Duration startPosition,
    required String? subtitleTrackId,
    required bool forceTranscode,
  }) async {
    try {
      // Jellyfin needs its playback info before a resolver exists.
      await _session.candidates(CandidateScope.file);
      final (detail, version) = await _session.pickedVersion();
      if (version == null) {
        throw const CastBackendException(
          'This item has no playable file on the server.',
          CastFailureKind.mediaLoadFailed,
        );
      }

      final isChromecast = protocol == CastProtocolKind.chromecast;
      final subtitles = isChromecast
          ? await _session.receiverSubtitles(version)
          : const <CastSubtitleTrack>[];
      final burn = subtitles
          .where((t) => t.burnedIn && t.trackId == subtitleTrackId)
          .firstOrNull
          ?.trackId;
      final transcode = forceTranscode ||
          burn != null ||
          !receiverCanCopyVideo(version.videoCodec);

      final PlaybackPlan plan = isChromecast
          ? HlsPlan(
              strategy: transcode ? HlsStrategy.transcode : HlsStrategy.copy,
              rung: QualityRung.original,
              adaptive: false,
              reason: forceTranscode
                  ? PlanReason.fallbackFromFailure
                  : PlanReason.copyAccepted,
            )
          : const DirectPlayPlan(reason: PlanReason.directPlayAccepted);

      final resolver = _session.createReceiverResolver(detail, version,
          // Plex burns the part's selected stream; '0' clears a previous
          // choice when subtitles are off.
          burnSubtitleStreamId:
              subtitles.any((t) => t.burnedIn) ? (burn ?? '0') : null);
      final stream = await resolver.resolve(plan,
          fileId: version.id, startAt: startPosition);
      final sessionId = stream.sessionId;
      if (sessionId != null) _resolvers[sessionId] = resolver;

      return CastRoute(
        mediaUrl: stream.url,
        kind: CastRouteKind.directServer,
        mediaKind: CastRouteResolver.mediaKindFor(protocol),
        hlsSessionId: sessionId,
        subtitles: subtitles,
        transcoded: isChromecast && transcode,
      );
    } on SourceException catch (e) {
      throw CastBackendException(
          e.viewerMessage,
          switch (e.kind) {
            SourceErrorKind.unreachable => CastFailureKind.unreachable,
            SourceErrorKind.unauthorized => CastFailureKind.notAuthorized,
            _ => CastFailureKind.mediaLoadFailed,
          });
    }
  }

  @override
  Future<void> endServerSession(String sessionId) async {
    final resolver = _resolvers.remove(sessionId);
    if (resolver == null) return;
    try {
      await resolver.end(sessionId);
    } catch (_) {
      // The server ends an abandoned transcode on its own.
    }
  }

  @override
  CastProgressSink openProgress() => ReporterCastProgressSink(
      _session.createProgress() as PeriodicProgressReporter);
}

/// The [SourceCastBinder] the cast session manager is given.
Future<SourceCastBinding> bindSourceCast(
    Ref ref, SourceCastContent content) async {
  final id = content.item.sourceId;
  final media = ref.read(mediaSourceProvider(id));
  if (media == null) {
    throw const CastBackendException(
      'This server is no longer in the app.',
      CastFailureKind.unknown,
    );
  }
  if (media.source.account.needsReauth) {
    throw const CastBackendException(
      'Sign in to this server again to cast from it.',
      CastFailureKind.notAuthorized,
    );
  }
  if (ref.read(gatedSourceIdsProvider).contains(id)) {
    throw const CastBackendException(
      'Unlock the app to cast from this server.',
      CastFailureKind.unknown,
    );
  }
  final session = playbackSessionFor(media, content.item, content.versionId);
  if (session is! SourcePlaybackSession ||
      session is MydiaSourcePlaybackSession) {
    throw const CastBackendException(
      'Casting is not available for this server.',
      CastFailureKind.unknown,
    );
  }
  return SessionSourceCastBinding(session);
}
