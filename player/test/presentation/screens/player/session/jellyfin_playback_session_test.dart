import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/receiver_profile.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/sources/transcode_codecs.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/jellyfin_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

import '../../../../core/sources/jellyfin/fake_jellyfin_server.dart';
import '../../../../core/sources/jellyfin/jellyfin_media_source_test.dart'
    show build, jellyfinSid;

void main() {
  const movie =
      ItemRef(sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm2');

  ({JellyfinPlaybackSession session, FakeJellyfinServer server}) open() {
    final b = build();
    return (
      session:
          JellyfinPlaybackSession(source: b.source, item: movie, fileId: 'm2'),
      server: b.server,
    );
  }

  Future<StreamingSetup> setupOf(JellyfinPlaybackSession s) async =>
      ((await s.prepareStreaming(
              owner: Object(),
              onProgress: (_) {},
              isCurrent: () => true)) as StreamingReady)
          .setup;

  test('offers what the server allows, in order', () async {
    final o = open();
    final offer = (await o.session.candidates(CandidateScope.file)).offer!;
    expect(offer.fileId, 'm2');
    expect(offer.candidates.map((c) => c.strategy),
        ['DIRECT_PLAY', 'HLS_COPY', 'TRANSCODE']);
    expect(offer.candidates.first.mime, 'video/x-matroska');
    expect(offer.durationSeconds, 5400);
    expect(offer.height, 1080);
    expect(offer.bitrateBps, 8000000);
  });

  test('drops direct play when the server says the device cannot', () async {
    final o = open();
    o.server.directPlay = false;
    final offer = (await o.session.candidates(CandidateScope.file)).offer!;
    expect(offer.candidates.map((c) => c.strategy), ['HLS_COPY', 'TRANSCODE']);
  });

  test('a refused PlaybackInfo surfaces Jellyfin\'s reason', () async {
    final o = open();
    o.server.playbackErrorCode = 'NotAllowed';
    final prep = await o.session.prepareStreaming(
        owner: Object(), onProgress: (_) {}, isCurrent: () => true);
    expect((prep as StreamingUnavailable).message, contains('not allowed'));
  });

  test('detail lists the sidecar subtitle only, and fetches it', () async {
    final o = open();
    final tracks = (await o.session.detail())!.serverSubtitleTracks!;
    expect(tracks.single.id, '3');
    expect(tracks.single.format, 'srt');
    expect(await o.session.subtitleContent('3'), contains('Hola'));
  });

  test('direct play streams the static file with the auth header', () async {
    final o = open();
    final setup = await setupOf(o.session);
    expect(setup.memoryKey, 'source:$jellyfinSid');
    final source = await setup.createTransport(relayed: false).open(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
          fileId: 'm2',
          startAt: Duration.zero,
        );
    final url = Uri.parse(source.url);
    expect(url.path, '/Videos/m2/stream');
    expect(url.queryParameters['static'], 'true');
    expect(url.queryParameters['mediaSourceId'], 'm2');
    expect(url.queryParameters['playSessionId'], 'ps1');
    expect(source.url, isNot(contains(FakeJellyfinServer.token)));
    expect(source.headers['Authorization'],
        contains('Token="${FakeJellyfinServer.token}"'));
  });

  test('transcode builds the HLS master and ends the encode after', () async {
    final o = open();
    final setup = await setupOf(o.session);
    final transport = setup.createTransport(relayed: false);
    final source = await transport.open(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: 'm2',
      startAt: Duration.zero,
    );
    final url = Uri.parse(source.url);
    expect(url.path, '/Videos/m2/master.m3u8');
    final q = url.queryParameters;
    expect(q['mediaSourceId'], 'm2');
    expect(q['playSessionId'], 'ps1-0');
    expect(q['deviceId'], 'dev1');
    expect(q['VideoCodec'], 'h264');
    expect(q['AllowVideoStreamCopy'], 'false');
    expect(q['MaxStreamingBitrate'], '4000000');
    expect(q['MaxHeight'], '720');
    expect(q['SubtitleMethod'], 'External');
    await transport.endSession();
    final end = o.server.requests.last;
    expect('${end.method} ${end.url.path}', 'DELETE /Videos/ActiveEncodings');
    expect(end.url.queryParameters['playSessionId'], 'ps1-0');
    expect(end.url.queryParameters['deviceId'], 'dev1');
  });

  Future<Map<String, String>> copyQuery(List<String> videoCodecs) async {
    final b = build();
    final session = JellyfinPlaybackSession(
      source: b.source,
      item: movie,
      fileId: 'm2',
      profile: DeviceProfile(
        containers: const ['mp4', 'mkv'],
        videoCodecs: videoCodecs,
        audioCodecs: const ['aac'],
        hdrFormats: const [],
      ),
    );
    final source =
        await (await setupOf(session)).createTransport(relayed: false).open(
              const HlsPlan(
                strategy: HlsStrategy.copy,
                rung: QualityRung.original,
                adaptive: false,
                reason: PlanReason.fallbackFromFailure,
              ),
              fileId: 'm2',
              startAt: Duration.zero,
            );
    return Uri.parse(source.url).queryParameters;
  }

  test('copy keeps the source video codec the device decodes', () async {
    final q = await copyQuery(const ['h264', 'hevc']);
    expect(q['VideoCodec'], 'hevc,h264');
    expect(q['AllowVideoStreamCopy'], 'true');
    expect(q.containsKey('MaxHeight'), isFalse);
  });

  test('copy never asks for a source codec the device cannot decode', () async {
    final q = await copyQuery(const ['h264']);
    expect(q['VideoCodec'], 'h264');
  });

  test('progress: start, progress, watched, stopped', () async {
    final o = open();
    final setup = await setupOf(o.session);
    final reporter = setup.progress as JellyfinProgressReporter;
    await reporter.sendProgress(
        positionSeconds: 10, durationSeconds: 5400, paused: false);
    await reporter.sendProgress(
        positionSeconds: 20, durationSeconds: 5400, paused: true);
    await reporter.sendWatched();
    await reporter.sendStopped(positionSeconds: 30, durationSeconds: 5400);
    final calls = o.server.requests
        .where((r) => r.method == 'POST')
        .map((r) => r.url.path)
        .where((p) => p != '/Items/m2/PlaybackInfo')
        .toList();
    expect(calls, [
      '/Sessions/Playing',
      '/Sessions/Playing/Progress',
      '/UserPlayedItems/m2',
      '/Sessions/Playing/Stopped',
    ]);
    final progress = o.server.bodies
        .where((b) => b.$1 == '/Sessions/Playing/Progress')
        .single
        .$2;
    expect(progress['PositionTicks'], 20 * FakeJellyfinServer.ticks);
    expect(progress['IsPaused'], isTrue);
    expect(progress['PlaySessionId'], 'ps1');
    expect(progress['MediaSourceId'], 'm2');
  });

  test('receiver mode puts api_key in the HLS URL and asks for H.264',
      () async {
    final o = open();
    await o.session.candidates(CandidateScope.file);
    final version = (await o.session.loadDetail()).versions.first;
    final resolver = JellyfinStreamResolver(
      client: o.session.jellyfinClient,
      itemId: 'm2',
      version: version,
      playSessionId: 'ps',
      codecs: transcodeCodecs(receiverDeviceProfile),
      onPlayMethod: (_) {},
      forReceiver: true,
    );

    final stream = await resolver.resolve(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung.original,
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: 'm2',
      startAt: Duration.zero,
    );

    final url = Uri.parse(stream.url);
    expect(url.queryParameters['api_key'], FakeJellyfinServer.token);
    expect(url.queryParameters['VideoCodec'], 'h264');
    expect(url.queryParameters['AudioCodec'], 'aac,mp3');
    expect(stream.headers, isEmpty);
  });
}
