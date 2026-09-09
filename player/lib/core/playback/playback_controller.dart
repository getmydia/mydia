/// Owns the streaming session and executes plans against the live player.
///
/// The session-start mutation, its legacy fallback, the playlist readiness
/// probe and the session end all moved here from `PlayerScreen` unchanged in
/// behaviour. What is new is [replaceSource]: a source switch that keeps the
/// `Player`, ends the old session only after the new one has produced a
/// frame, and restores the old session if the new one never does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/quality_rung.dart';
import '../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../graphql/mutations/start_streaming_session_compat.dart';
import '../../graphql/mutations/start_streaming_session_legacy.graphql.dart';
import '../../graphql/schema.graphql.dart';
import '../player/stream_timeline.dart';
import '../player/web_session_limits.dart';
import 'playback_plan.dart';
import 'server_features.dart';
import 'stream_urls.dart';

typedef PlaylistProbe = Future<({int status, String body})> Function(
  String url,
  Map<String, String>? headers,
);

Future<({int status, String body})> httpPlaylistProbe(
  String url,
  Map<String, String>? headers,
) async {
  final response = await http.get(Uri.parse(url), headers: headers ?? const {});
  return (status: response.statusCode, body: response.body);
}

/// Everything the screen needs to open a plan on the player.
class PlaybackSource {
  const PlaybackSource({
    required this.url,
    required this.headers,
    required this.timeline,
    required this.fullPlaylist,
    required this.seekOnOpen,
    this.sessionId,
    this.effectiveRung,
  });

  final String url;
  final Map<String, String> headers;
  final StreamTimeline timeline;

  /// True for a FULL-mode session, whose positions are real positions.
  final bool fullPlaylist;

  /// Whether the caller must seek to the real position after opening. False
  /// only for a WINDOW session, whose start offset went into FFmpeg's `-ss`.
  final bool seekOnOpen;

  /// Null for direct play.
  final String? sessionId;

  /// The rung the server said it applied, for the label. Null when the
  /// server did not say (the legacy document selects no echo fields).
  final QualityRung? effectiveRung;
}

/// Completes when [positions] reports a value past the first one it reports.
///
/// A seek lands the first value; anything above it means frames are flowing.
Future<void> awaitFirstAdvance(
  Stream<Duration> positions, {
  required Duration timeout,
}) async {
  final iterator = StreamIterator(positions);
  Future<void> waitForAdvance() async {
    Duration? first;
    while (await iterator.moveNext()) {
      final position = iterator.current;
      first ??= position;
      if (position > first) return;
    }
    throw StateError('Position stream ended before playback advanced');
  }

  try {
    await waitForAdvance().timeout(timeout);
  } finally {
    // Future.timeout does not cancel its input. Explicitly release the
    // position listener when a failed source never sends another event.
    await iterator.cancel();
  }
}

class PlaybackController {
  PlaybackController({
    required GraphQLClient? Function() client,
    required StreamUrls urls,
    required ServerFeatures features,
    required bool relayed,
    PlaylistProbe probe = httpPlaylistProbe,
    Future<void> Function(Duration) wait = Future.delayed,
    this.firstAdvanceTimeout = const Duration(seconds: 60),
  })  : _client = client,
        _urls = urls,
        _features = features,
        _relayed = relayed,
        _probe = probe,
        _wait = wait;

  /// Resolved on every use rather than captured: a long playback can outlive
  /// a token refresh, and at dispose time the screen can only hand back what
  /// its `ref.listenManual` last saw, which may be null.
  final GraphQLClient? Function() _client;
  final StreamUrls _urls;
  final ServerFeatures _features;
  final bool _relayed;
  final PlaylistProbe _probe;
  final Future<void> Function(Duration) _wait;
  final Duration firstAdvanceTimeout;

  String? _sessionId;
  bool _switching = false;

  String? get sessionId => _sessionId;

  /// True for the whole of [replaceSource], including while it awaits.
  bool get switching => _switching;

  Future<PlaybackSource> open(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
    Duration? totalDuration,
    void Function(String message)? onProgress,
  }) async {
    switch (plan) {
      case DirectPlayPlan():
        final resolved = await _urls.directPlay(fileId);
        debugPrint('[PlaybackController] Direct play for file_id=$fileId');
        return PlaybackSource(
          url: resolved.url,
          headers: resolved.headers,
          timeline: StreamTimeline(totalDuration: totalDuration),
          fullPlaylist: false,
          seekOnOpen: true,
        );
      case HlsPlan():
        return _openHls(plan,
            fileId: fileId,
            startAt: startAt,
            totalDuration: totalDuration,
            onProgress: onProgress);
    }
  }

  Future<PlaybackSource> _openHls(
    HlsPlan plan, {
    required String fileId,
    required Duration startAt,
    required Duration? totalDuration,
    required void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Starting stream...');
    final session = await _startSession(plan, fileId: fileId, startAt: startAt);
    _sessionId = session.sessionId;
    debugPrint(
        '[PlaybackController] HLS session started: ${session.sessionId}');

    final full = session.playlistMode == Enum$PlaylistMode.FULL;
    final echoedDuration = session.duration;
    final duration = totalDuration ??
        (echoedDuration == null
            ? null
            : Duration(milliseconds: (echoedDuration * 1000).round()));
    // The echoed offset, not the requested one: the server clamps it and
    // `-ss` lands on a keyframe. A FULL playlist starts at zero regardless.
    final timeline = full
        ? StreamTimeline(totalDuration: duration)
        : StreamTimeline(
            startOffset: Duration(seconds: session.startPosition ?? 0),
            totalDuration: duration,
          );
    // Only a server that echoes caps gets to label the stream. The legacy
    // document selects none, so reading them there would label a capped
    // stream Original.
    final effective = _features.heightCap
        ? effectiveRungLabel(
            maxHeight: session.maxHeight, maxBitrateKbps: session.maxBitrate)
        : null;

    try {
      final resolved = _urls.hls(session.sessionId);
      debugPrint('[PlaybackController] HLS URL: ${resolved.url}');
      await _awaitPlaylist(resolved.url,
          headers: resolved.probeHeaders, onProgress: onProgress);

      return PlaybackSource(
        url: resolved.url,
        headers: resolved.headers,
        timeline: timeline,
        fullPlaylist: full,
        seekOnOpen: full,
        sessionId: session.sessionId,
        effectiveRung: effective,
      );
    } catch (_) {
      _sessionId = null;
      await _end(session.sessionId);
      rethrow;
    }
  }

  GraphQLClient _requireClient() {
    final client = _client();
    if (client == null) {
      throw StateError('no GraphQL client is available for streaming');
    }
    return client;
  }

  /// The session-start mutation with its legacy fallback, as the screen ran
  /// it: the current document first, and on a server that rejects `maxHeight`
  /// or `playlistMode` the legacy document, remembered per connection.
  Future<Mutation$StartStreamingSession$startStreamingSession> _startSession(
    HlsPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    final client = _requireClient();
    final strategy = plan.strategy == HlsStrategy.copy
        ? Enum$StreamingStrategy.HLS_COPY
        : Enum$StreamingStrategy.TRANSCODE;
    final startPosition = startAt.inSeconds > 0 ? startAt.inSeconds : null;
    final limits = webSessionLimits(relayed: _relayed);
    final maxBitrate = tighterCap(plan.rung.maxBitrateKbps, limits.maxBitrate);
    final maxHeight = tighterCap(plan.rung.height, limits.maxHeight);

    Future<QueryResult<Object?>> runLegacy() => client.mutate(
          MutationOptions(
            document: documentNodeMutationStartStreamingSessionLegacy,
            variables: Variables$Mutation$StartStreamingSessionLegacy(
              fileId: fileId,
              strategy: strategy,
              maxBitrate: maxBitrate,
              startPosition: startPosition,
            ).toJson(),
          ),
        );

    QueryResult<Object?> result;
    if (_features.heightCap) {
      result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationStartStreamingSession,
          variables: Variables$Mutation$StartStreamingSession(
            fileId: fileId,
            strategy: strategy,
            maxBitrate: maxBitrate,
            maxHeight: maxHeight,
            startPosition: startPosition,
            playlistMode: Enum$PlaylistMode.FULL,
          ).toJson(),
        ),
      );
      if (_looksLikeMissingHeightSupport(result)) {
        debugPrint('[PlaybackController] Server does not know maxHeight; '
            'retrying without the height cap');
        _features.heightCap = false;
        result = await runLegacy();
      }
    } else {
      result = await runLegacy();
    }

    if (result.hasException) {
      throw Exception('Failed to start streaming session: ${result.exception}');
    }
    final data = Mutation$StartStreamingSession.fromJson(
      withPlaylistModeDefault(result.data!),
    );
    final session = data.startStreamingSession;
    if (session == null) {
      throw Exception('No session data returned from server');
    }
    return session;
  }

  /// Absinthe's verbatim validation text for the two fields an old server
  /// lacks. Anything else is a real failure and is not retried.
  static bool _looksLikeMissingHeightSupport(QueryResult<Object?> result) {
    final errors = result.exception?.graphqlErrors ?? const [];
    return errors.any((error) {
      final message = error.message;
      return message.contains('Unknown argument "maxHeight"') ||
          message.contains('Cannot query field "maxHeight"') ||
          message.contains('Unknown argument "playlistMode"') ||
          message.contains('Cannot query field "playlistMode"');
    });
  }

  /// Polls the manifest until it lists three segments, with the backoff the
  /// screen used. A FULL playlist is complete on the first poll.
  Future<void> _awaitPlaylist(
    String url, {
    required Map<String, String>? headers,
    required void Function(String message)? onProgress,
  }) async {
    const maxRetries = 20;
    const minSegments = 3;
    const baseDelay = Duration(milliseconds: 500);
    const maxDelay = Duration(milliseconds: 3000);

    for (var i = 0; i < maxRetries; i++) {
      try {
        final response = await _probe(url, headers);
        if (response.status == 200) {
          final segments = '.ts'.allMatches(response.body).length;
          if (segments >= minSegments) return;
          final percentage = (segments / minSegments * 100).round();
          onProgress?.call('Preparing stream... $percentage%');
        } else {
          onProgress?.call('Starting transcoding... (${i + 1}/$maxRetries)');
        }
      } catch (e) {
        debugPrint('[PlaybackController] Playlist probe failed '
            '(attempt ${i + 1}/$maxRetries): $e');
        onProgress?.call('Starting transcoding... (${i + 1}/$maxRetries)');
      }
      final delay = Duration(
        milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
            .clamp(baseDelay.inMilliseconds, maxDelay.inMilliseconds)
            .toInt(),
      );
      await _wait(delay);
    }
    throw Exception('Playlist not ready after maximum retry attempts');
  }

  /// Switches to [plan] at [realPosition] without disposing the player.
  ///
  /// [attach] opens the source on the player and returns its position
  /// stream. The old session is ended only after that stream advances, so
  /// the frames still on screen are never cut. If the new source fails to
  /// open or never advances within [firstAdvanceTimeout], its session is
  /// ended, the old one is kept, and the error is rethrown.
  Future<PlaybackSource> replaceSource(
    PlaybackPlan plan, {
    required String fileId,
    required Duration realPosition,
    Duration? totalDuration,
    required Future<Stream<Duration>> Function(PlaybackSource source) attach,
    void Function(String message)? onProgress,
  }) async {
    if (_switching) throw StateError('a source switch is already in flight');
    _switching = true;
    final previous = _sessionId;
    _sessionId = null;
    try {
      final PlaybackSource source;
      try {
        source = await open(plan,
            fileId: fileId,
            startAt: realPosition,
            totalDuration: totalDuration,
            onProgress: onProgress);
      } catch (_) {
        _sessionId = previous;
        rethrow;
      }
      try {
        final positions = await attach(source);
        await awaitFirstAdvance(positions, timeout: firstAdvanceTimeout);
      } catch (_) {
        final failed = _sessionId;
        _sessionId = previous;
        if (failed != null) await _end(failed);
        rethrow;
      }
      if (previous != null) await _end(previous);
      return source;
    } finally {
      _switching = false;
    }
  }

  /// Ends the current session, if any. Safe to call more than once.
  Future<void> endSession() async {
    final id = _sessionId;
    _sessionId = null;
    if (id != null) await _end(id);
  }

  Future<void> _end(String sessionId) async {
    final client = _client();
    if (client == null) {
      debugPrint('[PlaybackController] Cannot end session $sessionId: '
          'no GraphQL client resolved yet');
      return;
    }
    debugPrint('[PlaybackController] Terminating HLS session: $sessionId');
    try {
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationEndStreamingSession,
          variables:
              Variables$Mutation$EndStreamingSession(sessionId: sessionId)
                  .toJson(),
        ),
      );
      if (result.hasException) {
        debugPrint('[PlaybackController] Failed to terminate HLS session: '
            '${result.exception}');
      }
    } catch (e) {
      debugPrint('[PlaybackController] Error terminating HLS session: $e');
    }
  }
}
