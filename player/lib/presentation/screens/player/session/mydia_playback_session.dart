/// [PlaybackSession] over one Mydia instance's [MydiaClient].
///
/// Every method sends the document and variables the player screen sent
/// before the move. Changing either changes playback. There is no client-side
/// cache or timeout: every call goes to the server.
library;

import 'package:flutter/foundation.dart';

import '../../../../core/p2p/media_proxy.dart';
import '../../../../core/playback/candidates_from_graphql.dart';
import '../../../../core/playback/playback_controller.dart';
import '../../../../core/playback/stream_urls.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/player/progress_service.dart';
import '../../../../core/sources/current_source_status.dart';
import '../../../../core/sources/mydia/mydia_credentials.dart';
import '../../../../core/sources/mydia/mydia_proxy.dart';
import '../../../../core/sources/mydia/mydia_source.dart';
import '../../../../core/sources/mydia/root_typename.dart';
import '../../../../domain/models/media_segment.dart';
import '../../../../domain/models/subtitle_candidate.dart';
import '../../../../domain/models/subtitle_search_outcome.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/sources/source_error.dart';
import '../../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../../graphql/mutations/download_subtitle.graphql.dart';
import '../../../../graphql/mutations/set_audio_language_preference.graphql.dart';
import '../../../../graphql/mutations/set_subtitle_offset.graphql.dart';
import '../../../../graphql/mutations/set_subtitle_preference.graphql.dart';
import '../../../../graphql/queries/episode_detail.graphql.dart';
import '../../../../graphql/queries/media_segments.graphql.dart';
import '../../../../graphql/queries/movie_detail.graphql.dart';
import '../../../../graphql/queries/season_episodes.graphql.dart';
import '../../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../../graphql/queries/subtitle_content.graphql.dart';
import '../../../../graphql/queries/subtitle_preference.graphql.dart';
import '../../../../graphql/queries/subtitle_search.graphql.dart';
import '../../../../graphql/queries/subtitle_track_settings.graphql.dart';
import '../../../../graphql/schema.graphql.dart';
import '../../detail/detail_links.dart';
import '../subtitle_preference.dart';
import 'playback_session.dart';
import 'playback_session_types.dart';

class MydiaPlaybackSession implements PlaybackSession {
  MydiaPlaybackSession({
    required this.source,
    required this.item,
    required this.fileId,
    this.showId,
    this.seasonNumber,
    required MediaProxy Function() proxy,
  }) : _proxy = proxy;

  /// The instance this playback belongs to.
  final MydiaSource source;

  @override
  final ItemRef item;

  /// The file the route names, or `'offline'` for a downloaded file whose
  /// server id is unknown.
  final String fileId;
  final String? showId;
  final int? seasonNumber;
  final MediaProxy Function() _proxy;

  bool get _isEpisode => item.kind == ItemKind.episode;

  @override
  bool get canWrite => true;

  @override
  Set<PlaybackFeature> get features => PlaybackFeature.values.toSet();

  @override
  bool get reachable => !isOffline(source.statusListenable.value);

  @override
  String episodeLocation({
    required String episodeId,
    required String fileId,
    required String title,
    required int seasonNumber,
    required String? showId,
  }) =>
      sourcePlayerLocation(
        ItemRef(
          sourceId: item.sourceId,
          kind: ItemKind.episode,
          externalId: episodeId,
        ),
        fileId: fileId,
        title: title,
        extra: {
          'seasonNumber': '$seasonNumber',
          if (showId != null) 'showId': showId,
        },
      );

  @override
  Future<ProgressReporter> openProgress() async =>
      ProgressService(source.client);

  /// Credentials, then the p2p proxy or the server URL, then the transport.
  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    final client = source.client;
    final MydiaCredentials credentials;
    try {
      credentials = await client.credentials();
    } on SourceException catch (e) {
      return StreamingUnavailable(e.viewerMessage);
    }
    if (!isCurrent()) return const StreamingSuperseded();

    final serverUrl = credentials.serverUrl?.replaceFirst(RegExp(r'/+$'), '');
    final target = source.source.account.id;
    final StreamUrls urls;
    if (credentials.isP2p) {
      onProgress('Connecting via P2P...');
      // Held against the screen's State, released at its dispose. A re-run
      // re-targets the proxy without stacking holds.
      await mydiaProxyBase(_proxy(), credentials, owner: owner, target: target);
      if (!isCurrent()) return const StreamingSuperseded();
      urls = ProxyStreamUrls(_proxy(), target: target);
    } else if (serverUrl == null) {
      return const StreamingUnavailable('Server URL not available');
    } else {
      urls = HttpStreamUrls(
        serverUrl: serverUrl,
        bearerToken: credentials.accessToken,
        mediaToken: client.ensureValidMediaToken,
      );
    }

    return StreamingReady(StreamingSetup(
      memoryKey: credentials.nodeAddr ?? serverUrl!,
      viaP2p: credentials.isP2p,
      progress: ProgressService(client),
      scrubThumbnails: serverUrl == null
          ? null
          : (
              serverUrl: serverUrl,
              token: credentials.accessToken,
              isP2PMode: credentials.isP2p,
            ),
      createTransport: ({required bool relayed}) => PlaybackController(
        client: client,
        urls: urls,
        relayed: relayed,
      ),
    ));
  }

  @override
  Future<WriteOutcome> saveSubtitleOffset({
    required String trackRef,
    required int offsetMs,
  }) async {
    try {
      await source.client.request(
        documentNodeMutationSetSubtitleOffset,
        Variables$Mutation$SetSubtitleOffset(
          mediaFileId: fileId,
          trackRef: trackRef,
          offsetMs: offsetMs,
        ).toJson(),
      );
      return WriteOutcome.done;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not save subtitle delay: $e');
      return WriteOutcome.failed;
    }
  }

  @override
  Future<List<String>?> rememberAudioLanguage(String language) async {
    try {
      final data = await source.client.request(
        documentNodeMutationSetAudioLanguagePreference,
        Variables$Mutation$SetAudioLanguagePreference(
          fileId: fileId,
          language: language,
        ).toJson(),
      );
      final updated = (data['setAudioLanguagePreference']
          as Map<String, Object?>?)?['preferredAudioLanguages'];
      debugPrint('[PlayerScreen] Remembered audio language: $language');
      return updated is List ? updated.cast<String>() : null;
    } catch (e) {
      // A server too old to know this mutation answers with a GraphQL
      // validation error. That is a version gap, not a fault, and it stays
      // silent for the viewer: the track they picked has already changed.
      debugPrint('[PlayerScreen] Could not remember audio language: $e');
      return null;
    }
  }

  @override
  Future<void> writeSubtitlePreference({
    required String fileId,
    required SubtitleTrack? resolved,
  }) async {
    try {
      await source.client.request(
        documentNodeMutationSetSubtitlePreference,
        Variables$Mutation$SetSubtitlePreference(
          fileId: fileId,
          mode: resolved == null
              ? Enum$SubtitlePreferenceMode.OFF
              : Enum$SubtitlePreferenceMode.TRACK,
          language: resolved?.language,
          forced: resolved?.forced,
          hearingImpaired: resolved?.hearingImpaired,
          trackTitle: resolved?.title,
        ).toJson(),
      );
      debugPrint('[PlayerScreen] Remembered subtitle preference');
    } catch (e) {
      debugPrint('[PlayerScreen] Could not remember subtitle preference: $e');
    }
  }

  /// Every call goes to the server, never to a cache of an earlier answer.
  /// The primary call is keyed by the specific file the user selected, not by
  /// content id. When the server rejects that file id (e.g. a quality upgrade
  /// trashed it), the screen re-asks by media item and plays whatever the
  /// server ranks instead. That self-heal only works if the rejection is
  /// observable, and on the fallback paths the id used for playback comes
  /// from this response, so a stale answer would feed a dead file straight
  /// into playback.
  ///
  /// `serverRejected` says *why* a call failed, so the caller knows whether
  /// it is safe to retry against a different id. The server answers an
  /// unknown id with a GraphQL error (e.g. "file not found"), which surfaces
  /// as a [SourceException] that is not `unreachable`. A transport failure is
  /// `unreachable`. Only the former means "this id doesn't exist"; the latter
  /// means "we don't know".
  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    final (contentType, id) = switch (scope) {
      CandidateScope.file => ('file', fileId),
      CandidateScope.item => (
          _isEpisode ? 'episode' : 'movie',
          item.externalId
        ),
    };
    try {
      final data = Query$StreamingCandidates.fromJson(rootQuery(
        await source.client.request(
          documentNodeQueryStreamingCandidates,
          Variables$Query$StreamingCandidates(
            contentType: contentType,
            id: id,
          ).toJson(),
        ),
      )).streamingCandidates;
      if (data == null) return (offer: null, serverRejected: false);
      return (
        offer: PlaybackOffer(
          fileId: data.fileId,
          candidates: candidateStrategiesFrom(data.candidates),
          durationSeconds: data.metadata.duration,
          height: data.metadata.height,
          bitrateBps: data.metadata.bitrate,
          preferredAudioLanguages: data.metadata.preferredAudioLanguages,
        ),
        serverRejected: false,
      );
    } on SourceException catch (e) {
      debugPrint('[PlayerScreen] Failed to fetch candidates: $e');
      return (
        offer: null,
        serverRejected: e.kind != SourceErrorKind.unreachable,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return (offer: null, serverRejected: false);
    }
  }

  String get _root => _isEpisode ? 'episode' : 'movie';

  /// Fetches saved progress, runtime and the picked file's subtitle list.
  @override
  Future<PlaybackDetail?> detail() async {
    try {
      if (!_isEpisode) {
        final data = Query$MovieDetail.fromJson(rootQuery(
          await source.client.request(
            documentNodeQueryMovieDetail,
            Variables$Query$MovieDetail(id: item.externalId).toJson(),
          ),
        ));
        final movie = data.movie;
        return PlaybackDetail(
          savedPositionSeconds: movie?.progress?.positionSeconds,
          savedDurationSeconds: movie?.progress?.durationSeconds,
          lastWatchedAt:
              DateTime.tryParse(movie?.progress?.lastWatchedAt ?? ''),
          runtimeMinutes: movie?.runtime,
          serverSubtitleTracks: _subtitlesFor(movie?.files, fileId),
        );
      }
      final data = Query$EpisodeDetail.fromJson(rootQuery(
        await source.client.request(
          documentNodeQueryEpisodeDetail,
          Variables$Query$EpisodeDetail(id: item.externalId).toJson(),
        ),
      ));
      final episode = data.episode;
      return PlaybackDetail(
        savedPositionSeconds: episode?.progress?.positionSeconds,
        savedDurationSeconds: episode?.progress?.durationSeconds,
        lastWatchedAt:
            DateTime.tryParse(episode?.progress?.lastWatchedAt ?? ''),
        runtimeMinutes: episode?.runtime,
        serverSubtitleTracks: _subtitlesFor(episode?.files, fileId),
      );
    } catch (e) {
      debugPrint('Error fetching progress: $e');
      return null;
    }
  }

  /// The first file whose id is [fileId] decides. This always matches on
  /// the route's file id, never `playFileId`, so on the self-heal path in
  /// `_initializePlayer` (server rejected the selected file and re-ranked
  /// one instead) this is comparing against the id the server just
  /// rejected. No file matches, so external subtitles are silently
  /// dropped for that playback. Intentional for now; see [candidates] for
  /// the self-heal itself.
  static List<SubtitleTrack>? _subtitlesFor(
    List<Fragment$MediaFileFragment?>? files,
    String fileId,
  ) {
    if (files == null || files.isEmpty) return null;
    for (final file in files) {
      if (file == null) continue;
      if (file.id == fileId) {
        final subtitles = file.subtitles;
        if (subtitles == null) return null;
        return subtitles
            .whereType<Fragment$MediaFileFragment$subtitles>()
            .map(SubtitleTrack.fromGraphQL)
            .toList();
      }
    }
    return null;
  }

  /// A **separate query on purpose, and it has to stay that way.** An
  /// unknown field is a document-level validation error in GraphQL, not a
  /// field-level one, so a server predating the segments schema rejects the
  /// whole query the selection appears in and returns no data at all. Folded
  /// back into `MediaFileFragment` as a tidy-up, that would cost the resume
  /// position and the external subtitle list on every episode and movie
  /// detail view. Here it costs exactly one thing, the skip button.
  ///
  /// Matched on the route's file id, never `playFileId`, so on the
  /// self-heal path this finds no segments and skip markers are silently
  /// dropped for that playback. Intentional for now.
  @override
  Future<List<MediaSegment>?> segments() async {
    final root = _root;
    try {
      final data = await source.client.request(
        root == 'movie'
            ? documentNodeQueryMovieSegments
            : documentNodeQueryEpisodeSegments,
        root == 'movie'
            ? Variables$Query$MovieSegments(id: item.externalId).toJson()
            : Variables$Query$EpisodeSegments(id: item.externalId).toJson(),
      );
      return MediaSegment.forFile(
        rootQuery(data),
        root: root,
        fileId: fileId,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] No segments available: $e');
      return null;
    }
  }

  /// Matched on the route's file id, never `playFileId`, as for [segments].
  /// Never answered from a cache: a returning viewer must see the choice
  /// they made last time, not an older one.
  @override
  Future<FetchedSubtitlePreference?> subtitlePreference() async {
    final root = _root;
    try {
      final data = rootQuery(await source.client.request(
        root == 'movie'
            ? documentNodeQueryMovieSubtitlePreference
            : documentNodeQueryEpisodeSubtitlePreference,
        root == 'movie'
            ? Variables$Query$MovieSubtitlePreference(id: item.externalId)
                .toJson()
            : Variables$Query$EpisodeSubtitlePreference(id: item.externalId)
                .toJson(),
      ));
      final preferred = preferredSubtitleJsonForFile(
        data,
        root: root,
        fileId: fileId,
      );
      return FetchedSubtitlePreference(
        subtitlePreferenceFrom(
          mode: preferred?['mode'] as String?,
          language: preferred?['language'] as String?,
          forced: preferred?['forced'] as bool?,
          hearingImpaired: preferred?['hearingImpaired'] as bool?,
          trackTitle: preferred?['trackTitle'] as String?,
        ),
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Subtitle preference unavailable: $e');
      return null;
    }
  }

  /// Never answered from a cache: an old offset would become the baseline
  /// the next save adds to, silently overwriting a newer server offset.
  @override
  Future<Map<String, int>?> subtitleOffsets() async {
    try {
      final settings = Query$SubtitleTrackSettings.fromJson(rootQuery(
        await source.client.request(
          documentNodeQuerySubtitleTrackSettings,
          Variables$Query$SubtitleTrackSettings(mediaFileId: fileId).toJson(),
        ),
      )).subtitleTrackSettings;
      return {for (final s in settings) s.trackRef: s.offsetMs};
    } catch (e) {
      debugPrint('[PlayerScreen] Subtitle offsets unavailable: $e');
      return null;
    }
  }

  @override
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber) async {
    final showId = this.showId;
    if (showId == null) return null;
    try {
      final episodes = Query$SeasonEpisodes.fromJson(rootQuery(
        await source.client.request(
          documentNodeQuerySeasonEpisodes,
          Variables$Query$SeasonEpisodes(
            showId: showId,
            seasonNumber: seasonNumber,
          ).toJson(),
        ),
      )).seasonEpisodes;
      if (episodes == null) return null;
      return episodes
          .whereType<Query$SeasonEpisodes$seasonEpisodes>()
          .map(
            (e) => PlaybackEpisode(
              id: e.id,
              seasonNumber: e.seasonNumber,
              episodeNumber: e.episodeNumber,
              title: e.title,
              fileIds: e.files?.map((f) => f?.id).toList(),
              thumbnailUrl: e.thumbnailUrl,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('Error fetching season episodes: $e');
      return null;
    }
  }

  /// Search every subtitle provider the server has enabled for subtitles
  /// matching this file, in [languages].
  ///
  /// Never throws. The sheet renders [SubtitleSearchOutcome.error] inline,
  /// above the (empty) result list and below the language chips that
  /// produced it, so adjusting a language and retrying stays one tap away.
  /// Throwing instead would drop the viewer onto the sheet's generic
  /// "search failed" copy and lose the server's own reason, which is
  /// usually the actionable half ("this file has no hash or metadata IDs
  /// to search with" is not a retry).
  ///
  /// Never cached: each result carries a token the server signed for a
  /// fifteen minute window, so a replayed answer would hand back candidates
  /// whose download is already guaranteed to fail.
  @override
  Future<SubtitleSearchOutcome> searchSubtitles(List<String> languages) async {
    // The `'offline'` sentinel means this is a downloaded file playing with
    // no server file id behind it, so there is nothing to search *for*.
    // Caught here rather than left to the server, which would answer a
    // flat "media file not found" for what is really "you are offline".
    if (fileId == 'offline') {
      return const SubtitleSearchOutcome(
        results: [],
        providers: [],
        error: 'Subtitle search needs a connection to your server.',
      );
    }

    try {
      final payload = Query$SubtitleSearch.fromJson(rootQuery(
        await source.client.request(
          documentNodeQuerySubtitleSearch,
          Variables$Query$SubtitleSearch(
            mediaFileId: fileId,
            languages: languages,
          ).toJson(),
        ),
      )).subtitleSearch;
      return SubtitleSearchOutcome(
        results: payload.results.map(SubtitleCandidate.fromGraphQL).toList(),
        providers:
            payload.providers.map(SubtitleProviderStatus.fromGraphQL).toList(),
      );
    } on SourceException catch (e) {
      debugPrint('[PlayerScreen] Subtitle search failed: $e');
      return SubtitleSearchOutcome(
        results: const [],
        providers: const [],
        error: _friendlyError(e, 'Could not reach the server. Try again.'),
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Error searching subtitles: $e');
      return const SubtitleSearchOutcome(
        results: [],
        providers: [],
        error: 'Subtitle search failed. Try again.',
      );
    }
  }

  /// Download [candidate] into this file's library entry and return the
  /// track the server created for it.
  ///
  /// Throws on failure, which is what the sheet's contract asks for: it
  /// stays open on the results list so the viewer can pick a different
  /// release. A [SubtitleActionException] is shown verbatim, which is what
  /// carries the server's "search again" through on an expired token --
  /// the generic copy would invite re-tapping the same stale token forever.
  ///
  /// The returned track has no `content`: the body is fetched lazily when
  /// the selection is applied, the same path every other sidecar takes.
  @override
  Future<SubtitleTrack> downloadSubtitle(SubtitleCandidate candidate) async {
    if (fileId == 'offline') {
      throw const SubtitleActionException(
        'Downloading subtitles needs a connection to your server.',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = await source.client.request(
        documentNodeMutationDownloadSubtitle,
        Variables$Mutation$DownloadSubtitle(
          mediaFileId: fileId,
          token: candidate.token,
        ).toJson(),
      );
    } on SourceException catch (e) {
      debugPrint('[PlayerScreen] Subtitle download failed: $e');
      throw SubtitleActionException(
        _friendlyError(e, 'Could not download that subtitle. Try again.'),
      );
    }

    return SubtitleTrack.fromDownload(
      Mutation$DownloadSubtitle.fromJson(rootMutation(data)).downloadSubtitle,
    );
  }

  /// No client-side timeout: an embedded track has no body until the server
  /// extracts it with ffmpeg, which reads through the whole container (7.5 s
  /// and 10.7 s for two 2.4 GB 4K episodes). `MydiaClient.request` sets none.
  /// Over p2p the server stops waiting at 30 s and answers with an error.
  @override
  Future<String?> subtitleContent(String trackId) async {
    try {
      final content = Query$SubtitleContent.fromJson(rootQuery(
        await source.client.request(
          documentNodeQuerySubtitleContent,
          Variables$Query$SubtitleContent(
            mediaFileId: fileId,
            trackId: trackId,
          ).toJson(),
        ),
      )).subtitleContent;
      if (content == null || content.isEmpty) {
        debugPrint('[PlayerScreen] No subtitle content for $trackId');
        return null;
      }
      return content;
    } catch (e) {
      debugPrint(
          '[PlayerScreen] Failed to fetch subtitle content for $trackId: $e');
      return null;
    }
  }

  /// The line to show a viewer for a failed GraphQL operation.
  ///
  /// A resolver's own message is written for one -- "These search results
  /// expired. Search again.", "This file has no hash or metadata IDs to
  /// search with" -- and is the only part of the failure worth reading. A
  /// transport failure carries no such message, so those fall back to
  /// [fallback].
  static String _friendlyError(SourceException e, String fallback) {
    final message = e.message;
    if (message != null && message.isNotEmpty) return message;
    return fallback;
  }
}
