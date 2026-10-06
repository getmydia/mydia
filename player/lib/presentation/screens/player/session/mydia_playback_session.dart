/// [PlaybackSession] over Mydia's GraphQL API.
///
/// Every method sends the document, variables and fetch policy the player
/// screen sent before the move. Changing any of them changes playback.
library;

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../../core/playback/candidates_from_graphql.dart';
import '../../../../core/playback/playback_controller.dart';
import '../../../../core/playback/stream_urls.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/player/progress_service.dart';
import '../../../../core/sources/source.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/models/media_segment.dart';
import '../../../../domain/models/subtitle_candidate.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../../graphql/mutations/download_subtitle.graphql.dart';
import '../../../../graphql/mutations/set_audio_language_preference.graphql.dart';
import '../../../../graphql/mutations/set_subtitle_offset.graphql.dart';
import '../../../../graphql/mutations/set_subtitle_preference.graphql.dart';
import '../../../../graphql/schema.graphql.dart';
import '../../../../graphql/queries/episode_detail.graphql.dart';
import '../../../../graphql/queries/media_segments.graphql.dart';
import '../../../../graphql/queries/movie_detail.graphql.dart';
import '../../../../graphql/queries/season_episodes.graphql.dart';
import '../../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../../graphql/queries/subtitle_content.graphql.dart';
import '../../../../graphql/queries/subtitle_preference.graphql.dart';
import '../../../../graphql/queries/subtitle_search.graphql.dart';
import '../../../../graphql/queries/subtitle_track_settings.graphql.dart';
import '../../../../domain/models/subtitle_search_outcome.dart';
import '../subtitle_content_query.dart';
import '../subtitle_preference.dart';
import 'mydia_streaming.dart';
import 'playback_session.dart';
import 'playback_session_types.dart';

class MydiaPlaybackSession implements PlaybackSession {
  MydiaPlaybackSession({
    required GraphQLClient? Function() client,
    required Future<GraphQLClient> Function() awaitClient,
    required PlaybackTarget Function() target,
    required this.offline,
    MydiaStreamingDeps? streaming,
  })  : _client = client,
        _awaitClient = awaitClient,
        _target = target,
        _streaming = streaming;

  /// True while the app is in offline mode.
  final bool Function() offline;

  final MydiaStreamingDeps? _streaming;

  /// The screen's current client, null until the provider first resolves.
  final GraphQLClient? Function() _client;

  /// Waits for the client provider, for calls the screen made that way.
  final Future<GraphQLClient> Function() _awaitClient;
  final PlaybackTarget Function() _target;

  @override
  bool get canWrite => _client() != null;

  @override
  Set<PlaybackFeature> get features => PlaybackFeature.values.toSet();

  @override
  ItemRef get item => ItemRef(
        sourceId: SourceId.legacyMydia,
        kind: _target().mediaType == 'episode'
            ? ItemKind.episode
            : ItemKind.movie,
        externalId: _target().mediaId,
      );

  @override
  bool get reachable => !offline();

  @override
  String episodeLocation({
    required String episodeId,
    required String fileId,
    required String title,
    required int seasonNumber,
    required String? showId,
  }) =>
      '/player/episode/$episodeId?fileId=$fileId'
      '&title=${Uri.encodeComponent(title)}&showId=$showId'
      '&seasonNumber=$seasonNumber';

  @override
  Future<ProgressReporter> openProgress() async {
    final deps = _streaming;
    if (deps == null) {
      throw StateError('MydiaPlaybackSession was built without streaming');
    }
    final client = await _awaitClient();
    deps.adoptClient(client);
    return ProgressService(client);
  }

  /// The streaming branch of the player screen's `_initializePlayer`, moved
  /// unchanged: client, URL and token, the p2p proxy, then the transport.
  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    final deps = _streaming;
    if (deps == null) {
      throw StateError('MydiaPlaybackSession was built without streaming');
    }
    final graphqlClient = await _awaitClient();
    if (!isCurrent()) return const StreamingSuperseded();
    // Captured now rather than left to the screen's provider listener: a
    // dispose inside this window must still see the client that started a
    // session, or the HLS session leaks until its inactivity timeout.
    deps.adoptClient(graphqlClient);

    final serverUrl = await deps.serverUrl();
    final token = await deps.authToken();
    if (!isCurrent()) return const StreamingSuperseded();
    if (serverUrl == null || token == null) {
      return const StreamingUnavailable(
          'Server URL or authentication token not available');
    }

    final connectionState = deps.connection();
    final isP2PMode = connectionState.isP2PMode;
    if (isP2PMode) {
      final serverNodeAddr = connectionState.serverNodeAddr;
      if (serverNodeAddr == null) {
        throw Exception('Server node address not available for P2P connection');
      }
      onProgress('Connecting via P2P...');
      final proxy = deps.mediaProxy();
      // Held against the screen's State, released at its dispose. A re-run
      // re-targets the proxy without stacking holds.
      await proxy.start(
        owner: owner,
        targetPeer: serverNodeAddr,
        authToken: token,
      );
      if (!isCurrent()) return const StreamingSuperseded();
      debugPrint('[PlayerScreen] Media proxy serving at ${proxy.baseUrl}');
    }

    return StreamingReady(StreamingSetup(
      memoryKey: isP2PMode ? connectionState.serverNodeAddr! : serverUrl,
      progress: ProgressService(graphqlClient),
      scrubThumbnails: (
        serverUrl: serverUrl,
        token: token,
        isP2PMode: isP2PMode
      ),
      createTransport: ({required bool relayed}) => PlaybackController(
        client: _client,
        urls: isP2PMode
            ? ProxyStreamUrls(deps.mediaProxy())
            : HttpStreamUrls(
                serverUrl: serverUrl,
                bearerToken: token,
                mediaToken: deps.mediaToken,
              ),
        features: deps.serverFeatures(),
        relayed: relayed,
      ),
    ));
  }

  @override
  Future<WriteOutcome> saveSubtitleOffset({
    required String trackRef,
    required int offsetMs,
  }) async {
    final client = _client();
    if (client == null) return WriteOutcome.unavailable;
    try {
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationSetSubtitleOffset,
          variables: Variables$Mutation$SetSubtitleOffset(
            mediaFileId: _target().fileId,
            trackRef: trackRef,
            offsetMs: offsetMs,
          ).toJson(),
        ),
      );
      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Could not save subtitle delay: ${result.exception}');
        return WriteOutcome.failed;
      }
      return WriteOutcome.done;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not save subtitle delay: $e');
      return WriteOutcome.failed;
    }
  }

  @override
  Future<List<String>?> rememberAudioLanguage(String language) async {
    final client = _client();
    if (client == null) return null;
    try {
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationSetAudioLanguagePreference,
          variables: Variables$Mutation$SetAudioLanguagePreference(
            fileId: _target().fileId,
            language: language,
          ).toJson(),
        ),
      );
      if (result.hasException) {
        // A server too old to know this mutation answers with a GraphQL
        // validation error. That is a version gap, not a fault, and it stays
        // silent for the viewer: the track they picked has already changed.
        debugPrint('[PlayerScreen] Could not remember audio language: '
            '${result.exception}');
        return null;
      }
      final data =
          result.data?['setAudioLanguagePreference'] as Map<String, Object?>?;
      final updated = data?['preferredAudioLanguages'];
      debugPrint('[PlayerScreen] Remembered audio language: $language');
      return updated is List ? updated.cast<String>() : null;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not remember audio language: $e');
      return null;
    }
  }

  @override
  Future<void> writeSubtitlePreference({
    required String fileId,
    required SubtitleTrack? resolved,
  }) async {
    final client = _client();
    if (client == null) return;
    try {
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationSetSubtitlePreference,
          variables: Variables$Mutation$SetSubtitlePreference(
            fileId: fileId,
            mode: resolved == null
                ? Enum$SubtitlePreferenceMode.OFF
                : Enum$SubtitlePreferenceMode.TRACK,
            language: resolved?.language,
            forced: resolved?.forced,
            hearingImpaired: resolved?.hearingImpaired,
            trackTitle: resolved?.title,
          ).toJson(),
        ),
      );
      if (result.hasException) {
        debugPrint('[PlayerScreen] Could not remember subtitle preference: '
            '${result.exception}');
        return;
      }
      debugPrint('[PlayerScreen] Remembered subtitle preference');
    } catch (e) {
      debugPrint('[PlayerScreen] Could not remember subtitle preference: $e');
    }
  }

  GraphQLClient _requireClient() =>
      _client() ?? (throw StateError('no GraphQL client is available'));

  /// Fetch streaming candidates from the server via GraphQL.
  ///
  /// `networkOnly` is load-bearing. The primary call is keyed by the specific
  /// file the user selected, not by content id. When the server rejects that
  /// file id (e.g. a quality upgrade trashed it), the screen re-asks by media
  /// item and plays whatever the server ranks instead. That self-heal only
  /// works if the rejection is observable: a warm cache entry recorded before
  /// the file was trashed still holds a successful response, so serving it
  /// would keep `serverRejected` false and the self-heal would never fire. On
  /// the fallback paths (the offline sentinel, and the self-heal) the id used
  /// for playback comes from this response, so a stale cached response would
  /// also feed a dead file straight into playback.
  ///
  /// `cacheAndNetwork` is not the fix: on a one-shot `client.query()` it
  /// returns the cached result and discards the network one, which is the
  /// defect `core/graphql/watch/query_watcher.dart` documents. Nothing is
  /// lost by going to the network: every path that reaches here needs the
  /// server to serve a single byte.
  ///
  /// `serverRejected` says *why* a call failed, so the caller knows whether
  /// it is safe to retry against a different id. The server answers an
  /// unknown id with a GraphQL error (e.g. "file not found"), so the
  /// exception carries non-empty `graphqlErrors` and a null `linkException`.
  /// A transport failure looks the opposite: no `graphqlErrors`, a non-null
  /// `linkException`. Only the former means "this id doesn't exist"; the
  /// latter means "we don't know".
  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    final target = _target();
    final (contentType, id) = switch (scope) {
      CandidateScope.file => ('file', target.fileId),
      CandidateScope.item => (
          target.mediaType == 'movie' ? 'movie' : 'episode',
          target.mediaId,
        ),
    };
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: documentNodeQueryStreamingCandidates,
          variables: Variables$Query$StreamingCandidates(
            contentType: contentType,
            id: id,
          ).toJson(),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch candidates: ${result.exception}');
        final exception = result.exception;
        final serverRejected = exception != null &&
            exception.graphqlErrors.isNotEmpty &&
            exception.linkException == null;
        return (offer: null, serverRejected: serverRejected);
      }

      final data =
          Query$StreamingCandidates.fromJson(result.data!).streamingCandidates;
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
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return (offer: null, serverRejected: false);
    }
  }

  static String? _rootFor(String mediaType) => switch (mediaType) {
        'movie' => 'movie',
        'episode' => 'episode',
        _ => null,
      };

  /// Default fetch policy, as before. There is deliberately no
  /// `hasException` check: a partial answer still carries progress.
  @override
  Future<PlaybackDetail?> detail() async {
    final target = _target();
    try {
      if (target.mediaType == 'movie') {
        final result = await _requireClient().query(
          QueryOptions(
            document: documentNodeQueryMovieDetail,
            variables: Variables$Query$MovieDetail(id: target.mediaId).toJson(),
          ),
        );
        if (result.data == null) return null;
        final movie = Query$MovieDetail.fromJson(result.data!).movie;
        return PlaybackDetail(
          savedPositionSeconds: movie?.progress?.positionSeconds,
          savedDurationSeconds: movie?.progress?.durationSeconds,
          lastWatchedAt:
              DateTime.tryParse(movie?.progress?.lastWatchedAt ?? ''),
          runtimeMinutes: movie?.runtime,
          serverSubtitleTracks: _subtitlesFor(movie?.files, target.fileId),
        );
      }
      if (target.mediaType == 'episode') {
        final result = await _requireClient().query(
          QueryOptions(
            document: documentNodeQueryEpisodeDetail,
            variables:
                Variables$Query$EpisodeDetail(id: target.mediaId).toJson(),
          ),
        );
        if (result.data == null) return null;
        final episode = Query$EpisodeDetail.fromJson(result.data!).episode;
        return PlaybackDetail(
          savedPositionSeconds: episode?.progress?.positionSeconds,
          savedDurationSeconds: episode?.progress?.durationSeconds,
          lastWatchedAt:
              DateTime.tryParse(episode?.progress?.lastWatchedAt ?? ''),
          runtimeMinutes: episode?.runtime,
          serverSubtitleTracks: _subtitlesFor(episode?.files, target.fileId),
        );
      }
      return null;
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
    final target = _target();
    final root = _rootFor(target.mediaType);
    if (root == null) return null;
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: root == 'movie'
              ? documentNodeQueryMovieSegments
              : documentNodeQueryEpisodeSegments,
          variables: root == 'movie'
              ? Variables$Query$MovieSegments(id: target.mediaId).toJson()
              : Variables$Query$EpisodeSegments(id: target.mediaId).toJson(),
        ),
      );
      if (result.hasException) {
        debugPrint('[PlayerScreen] No segments available: ${result.exception}');
        return null;
      }
      return MediaSegment.forFile(
        result.data,
        root: root,
        fileId: target.fileId,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching segments: $e');
      return null;
    }
  }

  /// `networkOnly`: `client.query` defaults to `FetchPolicy.cacheFirst` over
  /// a persistent `HiveStore`, so a returning viewer would otherwise get the
  /// choice they made last time, not the current one.
  ///
  /// Matched on the route's file id, never `playFileId`, as for [segments].
  @override
  Future<FetchedSubtitlePreference?> subtitlePreference() async {
    final target = _target();
    final root = _rootFor(target.mediaType);
    if (root == null) return null;
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: root == 'movie'
              ? documentNodeQueryMovieSubtitlePreference
              : documentNodeQueryEpisodeSubtitlePreference,
          variables: root == 'movie'
              ? Variables$Query$MovieSubtitlePreference(id: target.mediaId)
                  .toJson()
              : Variables$Query$EpisodeSubtitlePreference(id: target.mediaId)
                  .toJson(),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );
      if (result.hasException) {
        debugPrint('[PlayerScreen] Subtitle preference unavailable: '
            '${result.exception}');
        return null;
      }
      final data = result.data;
      if (data == null) return null;
      final preferred = preferredSubtitleJsonForFile(
        data,
        root: root,
        fileId: target.fileId,
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
      debugPrint('[PlayerScreen] Error fetching subtitle preference: $e');
      return null;
    }
  }

  /// `networkOnly`: a cached offset would become the baseline the next save
  /// adds to, silently overwriting a newer server offset with an older one.
  @override
  Future<Map<String, int>?> subtitleOffsets() async {
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: documentNodeQuerySubtitleTrackSettings,
          variables: Variables$Query$SubtitleTrackSettings(
            mediaFileId: _target().fileId,
          ).toJson(),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );
      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Subtitle offsets unavailable: ${result.exception}');
        return null;
      }
      final data = result.data;
      if (data == null) {
        debugPrint('[PlayerScreen] No data returned for subtitle offsets');
        return null;
      }
      final settings =
          Query$SubtitleTrackSettings.fromJson(data).subtitleTrackSettings;
      return {for (final s in settings) s.trackRef: s.offsetMs};
    } catch (e) {
      debugPrint('[PlayerScreen] Subtitle offsets unavailable: $e');
      return null;
    }
  }

  @override
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber) async {
    final showId = _target().showId;
    if (showId == null) return null;
    try {
      final result = await _requireClient().query(
        QueryOptions(
          document: documentNodeQuerySeasonEpisodes,
          variables: Variables$Query$SeasonEpisodes(
            showId: showId,
            seasonNumber: seasonNumber,
          ).toJson(),
        ),
      );
      if (result.data == null) return null;
      final episodes =
          Query$SeasonEpisodes.fromJson(result.data!).seasonEpisodes;
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
  @override
  Future<SubtitleSearchOutcome> searchSubtitles(List<String> languages) async {
    final fileId = _target().fileId;
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
      final client = await _awaitClient();
      final result = await client.query(
        QueryOptions(
          document: documentNodeQuerySubtitleSearch,
          variables: Variables$Query$SubtitleSearch(
            mediaFileId: fileId,
            languages: languages,
          ).toJson(),
          // Never cached: each result carries a token the server signed for
          // a fifteen minute window, so a cache hit would hand back
          // candidates whose download is already guaranteed to fail.
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Subtitle search failed: ${result.exception}');
        return SubtitleSearchOutcome(
          results: const [],
          providers: const [],
          error: _friendlyError(
            result.exception,
            'Could not reach the server. Try again.',
          ),
        );
      }

      // `data` is only ever null alongside `hasException` in this client,
      // but papering over it with `?? const {}` would defer the failure
      // one line into the generated `fromJson`'s non-nullable cast.
      final data = result.data;
      if (data == null) {
        debugPrint('[PlayerScreen] Subtitle search returned no data');
        return const SubtitleSearchOutcome(
          results: [],
          providers: [],
          error: 'The server returned no results. Try again.',
        );
      }

      final payload = Query$SubtitleSearch.fromJson(data).subtitleSearch;
      return SubtitleSearchOutcome(
        results: payload.results.map(SubtitleCandidate.fromGraphQL).toList(),
        providers:
            payload.providers.map(SubtitleProviderStatus.fromGraphQL).toList(),
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
    final fileId = _target().fileId;
    if (fileId == 'offline') {
      throw const SubtitleActionException(
        'Downloading subtitles needs a connection to your server.',
      );
    }

    final client = await _awaitClient();
    final result = await client.mutate(
      MutationOptions(
        document: documentNodeMutationDownloadSubtitle,
        variables: Variables$Mutation$DownloadSubtitle(
          mediaFileId: fileId,
          token: candidate.token,
        ).toJson(),
      ),
    );

    if (result.hasException) {
      debugPrint(
          '[PlayerScreen] Subtitle download failed: ${result.exception}');
      throw SubtitleActionException(
        _friendlyError(
          result.exception,
          'Could not download that subtitle. Try again.',
        ),
      );
    }

    final data = result.data;
    if (data == null) {
      throw const SubtitleActionException(
        'The subtitle downloaded but the server returned nothing.',
      );
    }

    return SubtitleTrack.fromDownload(
      Mutation$DownloadSubtitle.fromJson(data).downloadSubtitle,
    );
  }

  @override
  Future<String?> subtitleContent(String trackId) async {
    try {
      final client = await _awaitClient();
      final result = await client.query(
        subtitleContentQueryOptions(
          mediaFileId: _target().fileId,
          trackId: trackId,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch subtitle content for $trackId: ${result.exception}');
        return null;
      }

      // `result.data` is only ever null alongside `hasException` in this
      // client, so this branch is not expected to run in practice, but it
      // is checked explicitly rather than papered over with `?? const {}`,
      // which would defer the same failure into the generated `fromJson`'s
      // non-nullable `__typename` cast.
      final data = result.data;
      if (data == null) {
        debugPrint(
            '[PlayerScreen] No data returned for subtitle content $trackId');
        return null;
      }

      final content = Query$SubtitleContent.fromJson(data).subtitleContent;
      if (content == null || content.isEmpty) {
        debugPrint('[PlayerScreen] No subtitle content for $trackId');
        return null;
      }
      return content;
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching subtitle content: $e');
      return null;
    }
  }

  /// The line to show a viewer for a failed GraphQL operation.
  ///
  /// A resolver's own message is written for one -- "These search results
  /// expired. Search again.", "This file has no hash or metadata IDs to
  /// search with" -- and is the only part of the failure worth reading. A
  /// transport failure carries no such message, only a `linkException`
  /// whose `toString` is a socket dump, so those fall back to [fallback].
  static String _friendlyError(OperationException? exception, String fallback) {
    final message = exception?.graphqlErrors.firstOrNull?.message;
    if (message != null && message.isNotEmpty) return message;
    return fallback;
  }
}
