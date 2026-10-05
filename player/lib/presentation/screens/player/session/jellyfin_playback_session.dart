/// Playing a Jellyfin item: the static file for direct play, the HLS master
/// playlist for copy and transcode, and the session reports Jellyfin's
/// dashboard shows.
library;

import '../../../../core/cast/receiver_profile.dart';
import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/device_profile.dart';
import '../../../../core/player/periodic_progress_reporter.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/jellyfin/jellyfin_client.dart';
import '../../../../core/sources/jellyfin/jellyfin_mapping.dart';
import '../../../../core/sources/jellyfin/jellyfin_media_source.dart';
import '../../../../core/sources/jellyfin/jellyfin_playback_info.dart';
import '../../../../core/sources/transcode_codecs.dart';
import '../../../../domain/models/cast_device.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/sources/source_error.dart';
import 'playback_session_types.dart';
import 'source_playback_session.dart';

/// What the server allows, in the planner's order. With no answer from the
/// server yet, everything is offered and the planner decides.
List<CandidateStrategy> jellyfinCandidates(
  MediaVersion v,
  JellyfinSourceSupport? support,
) =>
    [
      if (support?.directPlay ?? true)
        CandidateStrategy(
          strategy: 'DIRECT_PLAY',
          mime: containerMime(v.container),
          videoCodec: v.videoCodec,
        ),
      if (support?.directStream ?? true)
        CandidateStrategy(
          strategy: 'HLS_COPY',
          mime: 'application/x-mpegURL',
          videoCodec: v.videoCodec,
        ),
      if (support?.transcoding ?? true)
        const CandidateStrategy(
          strategy: 'TRANSCODE',
          mime: 'application/x-mpegURL',
          videoCodec: 'h264',
        ),
    ];

class JellyfinPlaybackSession extends SourcePlaybackSession {
  JellyfinPlaybackSession({
    required JellyfinMediaSource source,
    required super.item,
    required super.fileId,
    DeviceProfile? profile,
  })  : _jellyfin = source,
        _profile = profile,
        super(source: source);

  final JellyfinMediaSource _jellyfin;

  JellyfinClient get jellyfinClient => _jellyfin.client;
  final DeviceProfile? _profile;

  Future<JellyfinPlaybackInfo>? _info;
  JellyfinPlaybackInfo? _loaded;
  String? _mediaSourceId;

  /// DirectPlay, DirectStream or Transcode: set by the resolver, read by
  /// the progress reports.
  String _playMethod = 'DirectPlay';

  /// The picked version's playback info, fetched once. A failure is not
  /// cached.
  Future<JellyfinPlaybackInfo> _playbackInfo() {
    final cached = _info;
    if (cached != null) return cached;
    final fresh = () async {
      final detail = await loadDetail();
      final version =
          detail.versions.where((v) => v.id == fileId).firstOrNull ??
              detail.versions.firstOrNull;
      if (version == null) throw const SourceException.notFound();
      _mediaSourceId = version.id;
      final info = await _jellyfin.playbackInfo(item.externalId,
          mediaSourceId: version.id,
          deviceProfile: jellyfinDeviceProfile(_profile));
      _loaded = info;
      return info;
    }();
    _info = fresh;
    fresh.then<void>((_) {}, onError: (Object _) {
      if (identical(_info, fresh)) _info = null;
    });
    return fresh;
  }

  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async {
    try {
      await _playbackInfo();
    } on SourceException catch (e) {
      return (offer: null, serverRejected: e.kind == SourceErrorKind.notFound);
    } catch (_) {
      return (offer: null, serverRejected: false);
    }
    return super.candidates(scope);
  }

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    try {
      await _playbackInfo();
    } on SourceException catch (e) {
      return StreamingUnavailable(e.viewerMessage);
    }
    return super.prepareStreaming(
        owner: owner, onProgress: onProgress, isCurrent: isCurrent);
  }

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) =>
      jellyfinCandidates(version, _loaded?.sources[version.id]);

  @override
  Future<String> fetchText(String path) => _jellyfin.client.text(path);

  @override
  ProgressReporter createProgress() => JellyfinProgressReporter(
        client: _jellyfin.client,
        itemId: item.externalId,
        mediaSourceId: _mediaSourceId ?? fileId,
        playSessionId: _loaded?.playSessionId ?? '',
        playMethod: () => _playMethod,
      );

  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      JellyfinStreamResolver(
        client: _jellyfin.client,
        itemId: item.externalId,
        version: version,
        playSessionId: _loaded?.playSessionId ?? '',
        codecs: transcodeCodecs(_profile),
        onPlayMethod: (method) => _playMethod = method,
      );

  @override
  StreamResolver createReceiverResolver(
    ItemDetail detail,
    MediaVersion version, {
    String? burnSubtitleStreamId,
  }) =>
      JellyfinStreamResolver(
        client: _jellyfin.client,
        itemId: item.externalId,
        version: version,
        playSessionId: _loaded?.playSessionId ?? '',
        codecs: transcodeCodecs(receiverDeviceProfile),
        onPlayMethod: (method) => _playMethod = method,
        forReceiver: true,
      );

  /// Jellyfin converts any text track, embedded or sidecar, to WebVTT.
  @override
  Future<List<CastSubtitleTrack>> receiverSubtitles(
      MediaVersion version) async {
    final credential = await _jellyfin.client.receiverQuery();
    return [
      for (final s in version.streams)
        if (s.kind == MediaStreamKind.subtitle &&
            !isImageSubtitleCodec(s.codec))
          CastSubtitleTrack(
            trackId: s.id,
            url: (await _jellyfin.client.url(
                    '/Videos/${item.externalId}/${version.id}/Subtitles/${s.id}/Stream.vtt',
                    credential))
                .toString(),
            label: s.title ?? s.language ?? 'Subtitles',
            language: s.language ?? 'und',
          ),
    ];
  }
}

class JellyfinStreamResolver implements StreamResolver {
  JellyfinStreamResolver({
    required this.client,
    required this.itemId,
    required this.version,
    required this.playSessionId,
    required this.codecs,
    required this.onPlayMethod,
    this.forReceiver = false,
  });

  final JellyfinClient client;
  final String itemId;
  final MediaVersion version;
  final String playSessionId;
  final ({List<String> video, List<String> audio}) codecs;
  final void Function(String method) onPlayMethod;

  /// A cast receiver cannot send headers, so the token rides in the URL.
  final bool forReceiver;
  int _starts = 0;

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    final headers =
        forReceiver ? const <String, String>{} : await client.headers();
    final credential =
        forReceiver ? await client.receiverQuery() : const <String, String>{};
    switch (plan) {
      case DirectPlayPlan():
        onPlayMethod('DirectPlay');
        return ResolvedStream(
          url: (await client.url('/Videos/$itemId/stream', {
            'static': 'true',
            'mediaSourceId': version.id,
            'playSessionId': playSessionId,
            ...credential,
          }))
              .toString(),
          headers: headers,
        );
      case HlsPlan(:final strategy, :final rung):
        final copy = strategy == HlsStrategy.copy;
        onPlayMethod(copy ? 'DirectStream' : 'Transcode');
        // Each start is its own encode, ended on its own.
        final session = '$playSessionId-${_starts++}';
        final deviceId = (await client.identity()).deviceId;
        return ResolvedStream(
          url: (await client.url('/Videos/$itemId/master.m3u8', {
            'mediaSourceId': version.id,
            'playSessionId': session,
            'deviceId': deviceId,
            'SegmentContainer': 'ts',
            // Copy keeps the source codec when this device decodes it; the
            // device's own codecs follow, so a fallback encode targets one
            // it can play rather than the source's.
            'VideoCodec': copy
                ? {
                    if (version.videoCodec case final v?
                        when codecs.video.contains(v))
                      v,
                    ...codecs.video,
                  }.join(',')
                : 'h264',
            'AudioCodec': codecs.audio.join(','),
            'AllowVideoStreamCopy': '$copy',
            'AllowAudioStreamCopy': 'true',
            'SubtitleMethod': 'External',
            if (rung.maxBitrateKbps case final kbps?)
              'MaxStreamingBitrate': '${kbps * 1000}',
            if (rung.height case final height?) 'MaxHeight': '$height',
            ...credential,
          }))
              .toString(),
          headers: headers,
          sessionId: session,
        );
    }
  }

  @override
  Future<void> end(String sessionId) async => client.send(
        'DELETE',
        '/Videos/ActiveEncodings',
        query: {
          'deviceId': (await client.identity()).deviceId,
          'playSessionId': sessionId,
        },
      );
}

class JellyfinProgressReporter extends PeriodicProgressReporter {
  JellyfinProgressReporter({
    required this.client,
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.playMethod,
  });

  final JellyfinClient client;
  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final String Function() playMethod;
  bool _started = false;

  Map<String, dynamic> _body(int positionSeconds, {bool? paused}) => {
        'ItemId': itemId,
        'MediaSourceId': mediaSourceId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionSeconds * jellyfinTicksPerSecond,
        'PlayMethod': playMethod(),
        'CanSeek': true,
        if (paused != null) 'IsPaused': paused,
      };

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) {
    // The first report opens the session in Jellyfin's dashboard.
    final path = _started ? '/Sessions/Playing/Progress' : '/Sessions/Playing';
    _started = true;
    return client.send('POST', path,
        body: _body(positionSeconds, paused: paused));
  }

  @override
  Future<void> sendWatched() => client.send('POST', '/UserPlayedItems/$itemId',
      query: {'userId': client.userId});

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) =>
      client.send('POST', '/Sessions/Playing/Stopped',
          body: _body(positionSeconds));
}
