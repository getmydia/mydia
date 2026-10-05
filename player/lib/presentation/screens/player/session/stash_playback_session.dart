/// Playing a Stash scene: its direct stream, or its HLS transcode at a
/// named resolution; activity and play count for progress.
library;

import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/periodic_progress_reporter.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/stash/stash_client.dart';
import '../../../../core/sources/stash/stash_documents.dart';
import '../../../../core/sources/stash/stash_media_source.dart';
import '../../../../domain/sources/item.dart';
import 'source_playback_session.dart';

/// Stash's `StreamingResolutionEnum` for a rung height; the original when
/// the rung caps nothing.
String stashResolutionFor(int? height) {
  if (height == null) return 'ORIGINAL';
  if (height <= 240) return 'LOW';
  if (height <= 480) return 'STANDARD';
  if (height <= 720) return 'STANDARD_HD';
  if (height <= 1080) return 'FULL_HD';
  return 'FOUR_K';
}

class StashPlaybackSession extends SourcePlaybackSession {
  StashPlaybackSession({
    required StashMediaSource source,
    required super.item,
    required super.fileId,
  })  : _stash = source,
        super(source: source);

  final StashMediaSource _stash;

  StashClient get stashClient => _stash.client;

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) => [
        CandidateStrategy(
          strategy: 'DIRECT_PLAY',
          mime: version.container == 'webm' ? 'video/webm' : 'video/mp4',
          videoCodec: version.videoCodec,
        ),
        const CandidateStrategy(
          strategy: 'TRANSCODE',
          mime: 'application/x-mpegURL',
          videoCodec: 'h264',
        ),
      ];

  @override
  Future<String> fetchText(String path) => _stash.client.text(path);

  @override
  ProgressReporter createProgress() =>
      StashProgressReporter(client: _stash.client, sceneId: item.externalId);

  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      StashStreamResolver(client: _stash.client, sceneId: item.externalId);
}

class StashStreamResolver implements StreamResolver {
  StashStreamResolver({
    required this.client,
    required this.sceneId,
    this.forReceiver = false,
  });

  final StashClient client;
  final String sceneId;

  /// A cast receiver cannot send headers, so the API key rides in the URL.
  final bool forReceiver;

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    final path = switch (plan) {
      DirectPlayPlan() => '/scene/$sceneId/stream',
      HlsPlan(:final rung) => '/scene/$sceneId/stream.m3u8'
          '?resolution=${stashResolutionFor(rung.height)}',
    };
    final url = await client.url(path);
    if (!forReceiver) {
      return ResolvedStream(
          url: url.toString(), headers: await client.headers());
    }
    return ResolvedStream(
      url: url.replace(queryParameters: {
        ...url.queryParameters,
        ...await client.receiverQuery(),
      }).toString(),
      headers: const {},
    );
  }

  /// Stash ends its own transcodes when the player stops asking.
  @override
  Future<void> end(String sessionId) async {}
}

class StashProgressReporter extends PeriodicProgressReporter {
  StashProgressReporter({
    required this.client,
    required this.sceneId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final StashClient client;
  final String sceneId;
  final DateTime Function() _clock;

  DateTime? _lastReportAt;
  bool _lastPaused = true;

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) {
    // Reports also fire on play, pause, seek and save, so the span since the
    // previous report is what was watched, and only when playback was
    // running through it. Stash sums this into its play duration.
    final now = _clock();
    final previous = _lastReportAt;
    final watched = previous != null && !_lastPaused
        ? now.difference(previous).inMilliseconds / 1000
        : 0.0;
    _lastReportAt = now;
    _lastPaused = paused;
    return client.query(stashSaveActivity, {
      'id': sceneId,
      'resume_time': positionSeconds.toDouble(),
      'playDuration': watched,
    });
  }

  @override
  Future<void> sendWatched() => client.query(stashAddPlay, {'id': sceneId});

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) =>
      client.query(stashSaveActivity, {
        'id': sceneId,
        'resume_time': positionSeconds.toDouble(),
        'playDuration': 0.0,
      });
}
