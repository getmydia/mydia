/// Playing a Plex item: the part file for direct play, Plex's universal
/// transcoder for HLS, timeline and scrobble for progress.
library;

import 'package:uuid/uuid.dart';

import '../../../../core/cast/receiver_profile.dart';
import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/device_profile.dart';
import '../../../../core/player/periodic_progress_reporter.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/plex/plex_media_source.dart';
import '../../../../core/sources/plex/plex_server_client.dart';
import '../../../../core/sources/transcode_codecs.dart';
import '../../../../domain/models/cast_device.dart';
import '../../../../domain/sources/item.dart';
import '../../../../domain/sources/source_error.dart';
import 'playback_session_types.dart';
import 'source_playback_session.dart';

List<CandidateStrategy> plexCandidates(MediaVersion v) => [
      if (v.streamPath != null)
        CandidateStrategy(
          strategy: 'DIRECT_PLAY',
          mime: containerMime(v.container),
          videoCodec: v.videoCodec,
        ),
      CandidateStrategy(
        strategy: 'HLS_COPY',
        mime: 'application/x-mpegURL',
        videoCodec: v.videoCodec,
      ),
      const CandidateStrategy(
        strategy: 'TRANSCODE',
        mime: 'application/x-mpegURL',
        videoCodec: 'h264',
      ),
    ];

/// The `X-Plex-Client-Profile-Extra` value: transcode HLS to codecs this
/// device decodes.
String plexProfileExtra(DeviceProfile? profile) {
  final codecs = transcodeCodecs(profile);
  return 'add-transcode-target(type=videoProfile&context=streaming'
      '&protocol=hls&container=mpegts'
      '&videoCodec=${codecs.video.join(',')}'
      '&audioCodec=${codecs.audio.join(',')})';
}

class PlexPlaybackSession extends SourcePlaybackSession {
  PlexPlaybackSession({
    required PlexMediaSource source,
    required super.item,
    required super.fileId,
    DeviceProfile? profile,
  })  : _plex = source,
        _profile = profile,
        super(source: source);

  final PlexMediaSource _plex;

  PlexServerClient get plexClient => _plex.client;
  final DeviceProfile? _profile;

  /// One per playback; each transcode start gets its own session on top.
  final String _playbackId = const Uuid().v4();

  @override
  Set<PlaybackFeature> get features => const {PlaybackFeature.cast};

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) =>
      plexCandidates(version);

  @override
  Future<String> fetchText(String path) => _plex.client.text(path);

  @override
  ProgressReporter createProgress() =>
      PlexProgressReporter(client: _plex.client, ratingKey: item.externalId);

  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      PlexStreamResolver(
        client: _plex.client,
        ratingKey: item.externalId,
        version: version,
        mediaIndex: detail.versions.indexOf(version).clamp(0, 1 << 20),
        playbackId: _playbackId,
        profile: _profile,
      );

  @override
  StreamResolver createReceiverResolver(
    ItemDetail detail,
    MediaVersion version, {
    String? burnSubtitleStreamId,
  }) =>
      PlexStreamResolver(
        client: _plex.client,
        ratingKey: item.externalId,
        version: version,
        mediaIndex: detail.versions.indexOf(version).clamp(0, 1 << 20),
        playbackId: _playbackId,
        profile: receiverDeviceProfile,
        forReceiver: true,
        burnSubtitleStreamId: burnSubtitleStreamId,
      );

  /// Plex has no WebVTT conversion a receiver can fetch, so every track,
  /// image ones included, is offered burned in.
  @override
  Future<List<CastSubtitleTrack>> receiverSubtitles(
          MediaVersion version) async =>
      [
        for (final s in version.streams)
          if (s.kind == MediaStreamKind.subtitle)
            CastSubtitleTrack(
              trackId: s.id,
              url: '',
              label: s.title ?? s.language ?? 'Subtitles',
              language: s.language ?? 'und',
              burnedIn: true,
            ),
      ];
}

class PlexStreamResolver implements StreamResolver {
  PlexStreamResolver({
    required this.client,
    required this.ratingKey,
    required this.version,
    required this.mediaIndex,
    required this.playbackId,
    this.profile,
    this.forReceiver = false,
    this.burnSubtitleStreamId,
  });

  final PlexServerClient client;
  final String ratingKey;
  final MediaVersion version;
  final int mediaIndex;
  final String playbackId;
  final DeviceProfile? profile;

  /// A cast receiver cannot send headers, so the token and identity ride in
  /// the URL.
  final bool forReceiver;

  /// The part's subtitle stream to burn into the transcode; `'0'` turns
  /// subtitles off. Only read when [forReceiver], because a receiver cannot
  /// fetch a sidecar track the way the local player does.
  final String? burnSubtitleStreamId;
  int _starts = 0;

  Future<Map<String, String>> _playerHeaders() async {
    final all = await client.headers();
    return {
      for (final key in const [
        'X-Plex-Token',
        'X-Plex-Client-Identifier',
        'X-Plex-Product',
      ])
        if (all[key] case final value?) key: value,
      'X-Plex-Session-Identifier': playbackId,
    };
  }

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    switch (plan) {
      case DirectPlayPlan():
        final path = version.streamPath ??
            (throw const SourceException.unsupported(
                'Plex offers no direct file for this item.'));
        if (forReceiver) {
          return ResolvedStream(
            url: (await client.url(path, await _playerHeaders())).toString(),
            headers: const {},
          );
        }
        return ResolvedStream(
          url: (await client.url(path)).toString(),
          headers: await _playerHeaders(),
        );
      case HlsPlan():
        final burn = forReceiver ? burnSubtitleStreamId : null;
        if (burn != null) {
          // The transcoder burns the part's selected subtitle stream, so
          // select it first. Every Plex client's track picker sends this.
          await client.put('/library/parts/${version.id}',
              {'subtitleStreamID': burn, 'allParts': '1'});
        }
        final session = '$playbackId-${_starts++}';
        final height = plan.rung.height;
        final query = {
          'path': '/library/metadata/$ratingKey',
          'mediaIndex': '$mediaIndex',
          'partIndex': '0',
          'protocol': 'hls',
          'fastSeek': '1',
          'directPlay': '0',
          'directStream': plan.strategy == HlsStrategy.copy ? '1' : '0',
          'directStreamAudio': '1',
          'subtitles': burn != null && burn != '0' ? 'burn' : 'none',
          'offset': '0',
          'copyts': '1',
          'session': session,
          if (plan.rung.maxBitrateKbps case final kbps?)
            'maxVideoBitrate': '$kbps',
          if (height != null)
            'videoResolution': '${(height * 16 / 9).round()}x$height',
          // Plex reads X-Plex-* parameters from the query as well as headers.
          // PMS picks a base profile from X-Plex-Platform and has none for
          // Linux or macOS: the decision answers 400 "unable to find a
          // matching profile" there. Generic exists for every platform, and
          // the extra below says what this device actually decodes.
          'X-Plex-Client-Profile-Name': 'Generic',
          'X-Plex-Client-Profile-Extra': plexProfileExtra(profile),
        };
        final decision = await client.container(
            '/video/:/transcode/universal/decision', query);
        final code = decision['generalDecisionCode'] as int?;
        if (code != null && code >= 2000 && code < 3000) {
          throw SourceException.server(
              decision['generalDecisionText'] as String? ??
                  'Plex refused to convert this file.');
        }
        final headers = await _playerHeaders();
        return ResolvedStream(
          url: (await client.url('/video/:/transcode/universal/start.m3u8',
                  forReceiver ? {...query, ...headers} : query))
              .toString(),
          headers: forReceiver ? const {} : headers,
          sessionId: session,
        );
    }
  }

  @override
  Future<void> end(String sessionId) =>
      client.ping('/video/:/transcode/universal/stop', {'session': sessionId});
}

class PlexProgressReporter extends PeriodicProgressReporter {
  PlexProgressReporter({required this.client, required this.ratingKey});

  final PlexServerClient client;
  final String ratingKey;

  Future<void> _timeline(
          String state, int positionSeconds, int durationSeconds) =>
      client.ping('/:/timeline', {
        'ratingKey': ratingKey,
        'key': '/library/metadata/$ratingKey',
        'state': state,
        'time': '${positionSeconds * 1000}',
        'duration': '${durationSeconds * 1000}',
      });

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) =>
      _timeline(
          paused ? 'paused' : 'playing', positionSeconds, durationSeconds);

  @override
  Future<void> sendWatched() => client.ping('/:/scrobble', {
        'identifier': 'com.plexapp.plugins.library',
        'key': ratingKey,
      });

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) =>
      _timeline('stopped', positionSeconds, durationSeconds);
}
