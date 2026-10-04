/// A transport for servers that hand out stream URLs directly: Plex and
/// Stash. No readiness probe: both serve a complete HLS playlist and
/// transcode segments on demand, so positions are real positions and a
/// seek is a seek.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../player/stream_timeline.dart';
import 'playback_controller.dart' show PlaybackSource, awaitFirstAdvance;
import 'playback_plan.dart';
import 'playback_transport.dart';
import 'stream_urls.dart' show ResolvedSource;

class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.headers,
    this.sessionId,
  });

  final String url;

  /// Given to the player for every request, segments included. Carries the
  /// credential, which never goes in [url].
  final Map<String, String> headers;

  /// A server-side session to end later. Null when there is none.
  final String? sessionId;
}

abstract interface class StreamResolver {
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  });

  /// Best effort; failures are logged, never thrown.
  Future<void> end(String sessionId);
}

class SimplePlaybackTransport implements PlaybackTransport {
  SimplePlaybackTransport({
    required StreamResolver resolver,
    this.firstAdvanceTimeout = const Duration(seconds: 60),
  }) : _resolver = resolver;

  final StreamResolver _resolver;
  final Duration firstAdvanceTimeout;

  String? _sessionId;
  bool _switching = false;
  Completer<void> _lifetime = Completer<void>();
  final _owned = <String>{};

  @override
  String? get sessionId => _sessionId;

  @override
  bool get switching => _switching;

  @override
  ResolvedSource? sessionFile(String name) => null;

  @override
  Future<PlaybackSource> open(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
    Duration? totalDuration,
    void Function(String message)? onProgress,
  }) async {
    final lifetime = _lifetime;
    onProgress?.call('Starting stream...');
    final resolved =
        await _resolver.resolve(plan, fileId: fileId, startAt: startAt);
    final id = resolved.sessionId;
    if (id != null) _owned.add(id);
    if (lifetime.isCompleted) {
      if (id != null) await _endOwned(id);
      throw StateError('Playback ended');
    }
    _sessionId = id;
    return PlaybackSource(
      url: resolved.url,
      headers: resolved.headers,
      timeline: StreamTimeline(totalDuration: totalDuration),
      fullPlaylist: plan is HlsPlan,
      seekOnOpen: true,
      sessionId: id,
    );
  }

  @override
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
    final lifetime = _lifetime;
    final previous = _sessionId;
    _sessionId = null;
    PlaybackSource? source;
    try {
      source = await open(plan,
          fileId: fileId,
          startAt: realPosition,
          totalDuration: totalDuration,
          onProgress: onProgress);
      final positions = await attach(source);
      await awaitFirstAdvance(positions, timeout: firstAdvanceTimeout);
      if (lifetime.isCompleted) throw StateError('Playback ended');
      if (previous != null) await _endOwned(previous);
      return source;
    } catch (_) {
      if (!lifetime.isCompleted) _sessionId = previous;
      final failed = source?.sessionId;
      if (failed != null) await _endOwned(failed);
      rethrow;
    } finally {
      if (identical(lifetime, _lifetime)) _switching = false;
    }
  }

  @override
  Future<void> endSession() async {
    _lifetime.complete();
    _lifetime = Completer<void>();
    _sessionId = null;
    _switching = false;
    await Future.wait([for (final id in _owned.toList()) _endOwned(id)]);
  }

  Future<void> _endOwned(String sessionId) async {
    if (!_owned.remove(sessionId)) return;
    try {
      await _resolver.end(sessionId);
    } catch (e) {
      debugPrint('[SimplePlaybackTransport] Could not end $sessionId: $e');
    }
  }
}
