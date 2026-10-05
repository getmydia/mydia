/// The data half of a third-party playback session, built on the
/// source's neutral item detail. Transport and progress are the subclass's.
library;

import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/capabilities.dart';
import '../../../../core/sources/media_source.dart';
import '../../../../domain/models/media_segment.dart';
import '../../../../domain/models/subtitle_candidate.dart';
import '../../../../domain/models/subtitle_search_outcome.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/sources/library.dart' show Cursor;
import '../../../../domain/sources/source_error.dart';
import 'playback_session.dart';
import 'playback_session_types.dart';

/// The MIME type the player expects for a file in [container].
String containerMime(String? container) => switch (container) {
      'mkv' => 'video/x-matroska',
      'mp4' || 'm4v' || 'mov' => 'video/mp4',
      'avi' => 'video/x-msvideo',
      'ts' || 'mpegts' => 'video/mp2t',
      'webm' => 'video/webm',
      null => 'video/mp4',
      final other => 'video/$other',
    };

const _maxChildPages = 10;

abstract class SourcePlaybackSession implements PlaybackSession {
  SourcePlaybackSession({
    required this.source,
    required this.item,
    required this.fileId,
  });

  final MediaSource source;
  final ItemRef item;

  /// The version the viewer picked; the first one when it is gone.
  final String fileId;

  Future<ItemDetail>? _detail;

  Future<ItemDetail> loadDetail() {
    final cached = _detail;
    if (cached != null) return cached;
    final fresh = source.item(item);
    _detail = fresh;
    // A failure is not cached: a later call retries.
    fresh.then<void>((_) {}, onError: (Object _) {
      if (identical(_detail, fresh)) _detail = null;
    });
    return fresh;
  }

  Future<(ItemDetail, MediaVersion?)> _version() async {
    final detail = await loadDetail();
    final version = detail.versions.where((v) => v.id == fileId).firstOrNull ??
        detail.versions.firstOrNull;
    return (detail, version);
  }

  List<CandidateStrategy> candidatesFor(MediaVersion version);
  Future<String> fetchText(String path);
  ProgressReporter createProgress();
  StreamResolver createResolver(ItemDetail detail, MediaVersion version);

  @override
  Set<PlaybackFeature> get features => const {};

  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    try {
      final (_, version) = await _version();
      if (version == null) return (offer: null, serverRejected: true);
      final kbps = version.bitrateKbps;
      return (
        offer: PlaybackOffer(
          fileId: version.id,
          candidates: candidatesFor(version),
          durationSeconds: version.durationSeconds?.toDouble(),
          height: version.height,
          bitrateBps: kbps == null ? null : kbps * 1000,
        ),
        serverRejected: false,
      );
    } on SourceException catch (e) {
      return (offer: null, serverRejected: e.kind == SourceErrorKind.notFound);
    } catch (_) {
      return (offer: null, serverRejected: false);
    }
  }

  @override
  Future<PlaybackDetail?> detail() async {
    try {
      final (detail, version) = await _version();
      final duration =
          version?.durationSeconds ?? detail.summary.durationSeconds;
      final external = [
        for (final s in version?.streams ?? const <MediaStreamInfo>[])
          if (s.kind == MediaStreamKind.subtitle && s.externalPath != null)
            SubtitleTrack(
              id: s.id,
              language: s.language ?? 'und',
              title: s.title,
              format: s.codec ?? 'srt',
            ),
      ];
      return PlaybackDetail(
        savedPositionSeconds: detail.summary.userState.progressSeconds,
        savedDurationSeconds: duration,
        runtimeMinutes: duration == null ? null : (duration / 60).round(),
        // Embedded tracks come from the container through mpv; only
        // sidecars need the server.
        serverSubtitleTracks: external.isEmpty ? null : external,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> subtitleContent(String trackId) async {
    try {
      final (_, version) = await _version();
      final stream = version?.streams
          .where((s) => s.id == trackId && s.externalPath != null)
          .firstOrNull;
      if (stream == null) return null;
      return await fetchText(stream.externalPath!);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    try {
      final (detail, version) = await _version();
      if (!isCurrent()) return const StreamingSuperseded();
      if (version == null) {
        return const StreamingUnavailable(
            'This item has no playable file on the server.');
      }
      return StreamingReady(StreamingSetup(
        memoryKey: 'source:${source.id}',
        progress: createProgress(),
        createTransport: ({required bool relayed}) => SimplePlaybackTransport(
          resolver: createResolver(detail, version),
        ),
      ));
    } on SourceException catch (e) {
      return StreamingUnavailable(e.viewerMessage);
    }
  }

  @override
  Future<ProgressReporter> openProgress() =>
      throw UnsupportedError('only Mydia plays downloaded files');

  /// Null when the source cannot say. Detection is additive, so a failure
  /// costs the skip button and nothing else.
  @override
  Future<List<MediaSegment>?> segments() async {
    final skip = source.as<SkipSegments>();
    if (skip == null) return null;
    try {
      return await skip.skipSegments(item, versionId: fileId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<FetchedSubtitlePreference?> subtitlePreference() async => null;

  @override
  Future<Map<String, int>?> subtitleOffsets() async => null;

  @override
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber) async {
    try {
      final show = (await loadDetail()).show;
      if (show == null) return null;
      final seasons = await _allChildren(show);
      final season = seasons.where((s) => s.index == seasonNumber).firstOrNull;
      if (season == null) return null;
      final episodes = await _allChildren(season.ref);
      return [
        for (final e in episodes)
          PlaybackEpisode(
            id: e.ref.externalId,
            seasonNumber: e.parentIndex ?? seasonNumber,
            episodeNumber: e.index ?? 0,
            title: e.title,
            fileIds: [e.defaultVersionId],
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Every page of [parent]'s children, capped so a broken cursor cannot
  /// loop.
  Future<List<ItemSummary>> _allChildren(ItemRef parent) async {
    final all = <ItemSummary>[];
    Cursor? cursor;
    for (var page = 0; page < _maxChildPages; page++) {
      final result = await source.children(parent, cursor: cursor);
      all.addAll(result.items);
      cursor = result.nextCursor;
      if (cursor == null) break;
    }
    return all;
  }

  @override
  Future<SubtitleSearchOutcome> searchSubtitles(List<String> languages) async =>
      const SubtitleSearchOutcome(
        results: [],
        providers: [],
        error: 'Subtitle search is available on Mydia servers only.',
      );

  @override
  Future<SubtitleTrack> downloadSubtitle(SubtitleCandidate candidate) =>
      throw const SubtitleActionException(
          'Subtitle downloads are available on Mydia servers only.');

  @override
  bool get canWrite => false;

  @override
  Future<WriteOutcome> saveSubtitleOffset({
    required String trackRef,
    required int offsetMs,
  }) async =>
      WriteOutcome.unavailable;

  @override
  Future<List<String>?> rememberAudioLanguage(String language) async => null;

  @override
  String episodeLocation({
    required String episodeId,
    required String fileId,
    required String title,
    required int seasonNumber,
    required String? showId,
  }) =>
      Uri(
        path: '/s/${source.id.value}/player/$episodeId',
        queryParameters: {
          'kind': 'episode',
          'fileId': fileId,
          'title': title,
          if (showId != null) 'showId': showId,
          'seasonNumber': '$seasonNumber',
        },
      ).toString();

  @override
  Future<void> writeSubtitlePreference({
    required String fileId,
    required SubtitleTrack? resolved,
  }) async {}
}
