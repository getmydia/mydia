import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/receiver_profile.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/session/plex_playback_session.dart';

import '../../../../core/sources/plex/fake_plex_server.dart';
import '../../../../core/sources/plex/plex_media_source_test.dart' show build;

void main() {
  const sid = SourceId('acc1:owner:abc123');
  const movie = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: '101');

  ({PlexPlaybackSession session, FakePlexServer server}) open() {
    final b = build();
    return (
      session: PlexPlaybackSession(source: b.source, item: movie, fileId: '21'),
      server: b.server,
    );
  }

  test('offers direct play, copy and transcode for the part', () async {
    final fetch = await open().session.candidates(CandidateScope.file);
    final offer = fetch.offer!;
    expect(offer.fileId, '21');
    expect(offer.candidates.map((c) => c.strategy),
        ['DIRECT_PLAY', 'HLS_COPY', 'TRANSCODE']);
    expect(offer.durationSeconds, 5400);
    expect(offer.height, 1080);
    expect(offer.bitrateBps, 8000000);
  });

  test('detail carries runtime and the external subtitle only', () async {
    final detail = (await open().session.detail())!;
    expect(detail.runtimeMinutes, 90);
    final tracks = detail.serverSubtitleTracks!;
    expect(tracks.single.id, '33');
    expect(tracks.single.language, 'spa');
    expect(tracks.single.embedded, isFalse);
  });

  group('receiverSubtitleIdFor', () {
    test('null means off', () async {
      expect(await open().session.receiverSubtitleIdFor(null), isNull);
    });

    test('a sidecar id matches its source stream', () async {
      const local = SubtitleTrack(id: '33', language: 'spa');
      expect(await open().session.receiverSubtitleIdFor(local), '33');
    });

    test('an mpv track is matched by language', () async {
      const local = SubtitleTrack(id: 'mk_2', language: 'ENG', embedded: true);
      expect(await open().session.receiverSubtitleIdFor(local), '34');
    });

    test('no matching stream gives null', () async {
      const local = SubtitleTrack(id: 'mk_3', language: 'fre', embedded: true);
      expect(await open().session.receiverSubtitleIdFor(local), isNull);
      const unknown = SubtitleTrack(id: 'mk_4', language: 'und');
      expect(await open().session.receiverSubtitleIdFor(unknown), isNull);
    });
  });

  test('fetches an external subtitle body', () async {
    expect(await open().session.subtitleContent('33'), contains('Hola'));
  });

  test('direct play opens the part with the token in a header', () async {
    final o = open();
    final prep = await o.session.prepareStreaming(
        owner: Object(), onProgress: (_) {}, isCurrent: () => true);
    final setup = (prep as StreamingReady).setup;
    expect(setup.memoryKey, 'source:$sid');
    expect(setup.scrubThumbnails, isNull);
    final transport = setup.createTransport(relayed: false);
    final source = await transport.open(
      const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
      fileId: '21',
      startAt: Duration.zero,
    );
    expect(Uri.parse(source.url).path, '/library/parts/21/1700000000/file.mkv');
    expect(source.url, isNot(contains(FakePlexServer.token)));
    expect(source.headers['X-Plex-Token'], FakePlexServer.token);
  });

  test('transcode asks for a decision, starts HLS and stops it at the end',
      () async {
    final o = open();
    final setup = ((await o.session.prepareStreaming(
            owner: Object(),
            onProgress: (_) {},
            isCurrent: () => true)) as StreamingReady)
        .setup;
    final transport = setup.createTransport(relayed: false);
    final source = await transport.open(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: '21',
      startAt: Duration.zero,
    );
    final url = Uri.parse(source.url);
    expect(url.path, '/video/:/transcode/universal/start.m3u8');
    expect(url.queryParameters['path'], '/library/metadata/101');
    expect(url.queryParameters['directStream'], '0');
    expect(url.queryParameters['maxVideoBitrate'], '4000');
    expect(url.queryParameters['videoResolution'], '1280x720');
    // PMS has no platform profile for Linux or macOS and refuses those
    // without a named one.
    expect(url.queryParameters['X-Plex-Client-Profile-Name'], 'Generic');
    expect(url.queryParameters['session'], transport.sessionId);
    expect(o.server.requests.map((r) => r.url.path),
        contains('/video/:/transcode/universal/decision'));

    await transport.endSession();
    expect(
        o.server.requests.last.url.path, '/video/:/transcode/universal/stop');
    expect(o.server.requests.last.url.queryParameters['session'],
        url.queryParameters['session']);
  });

  test('a refused transcode surfaces the server reason', () async {
    final o = open();
    o.server.refuseTranscode = true;
    final setup = ((await o.session.prepareStreaming(
            owner: Object(),
            onProgress: (_) {},
            isCurrent: () => true)) as StreamingReady)
        .setup;
    await expectLater(
      setup.createTransport(relayed: false).open(
            const HlsPlan(
              strategy: HlsStrategy.copy,
              rung: QualityRung.original,
              adaptive: false,
              reason: PlanReason.copyAccepted,
            ),
            fileId: '21',
            startAt: Duration.zero,
          ),
      throwsA(predicate((e) => '$e'.contains('not supported by this server'))),
    );
  });

  test('progress goes to the timeline and watched to scrobble', () async {
    final o = open();
    final reporter = (await o.session.prepareStreaming(
            owner: Object(),
            onProgress: (_) {},
            isCurrent: () => true) as StreamingReady)
        .setup
        .progress as PlexProgressReporter;
    await reporter.sendProgress(
        positionSeconds: 60, durationSeconds: 5400, paused: false);
    final timeline = o.server.requests.last.url;
    expect(timeline.path, '/:/timeline');
    expect(timeline.queryParameters['state'], 'playing');
    expect(timeline.queryParameters['time'], '60000');
    expect(timeline.queryParameters['ratingKey'], '101');
    await reporter.sendWatched();
    expect(o.server.requests.last.url.path, '/:/scrobble');
  });

  test('a failed detail load is retried on the next call', () async {
    final o = open();
    o.server.status = 500;
    expect(await o.session.detail(), isNull);
    o.server.status = null;
    expect(await o.session.detail(), isNotNull);
  });

  test('receiver mode puts the token in the transcode URL, not headers',
      () async {
    final o = open();
    final detail = await o.session.loadDetail();
    final version = detail.versions.single;
    final resolver = PlexStreamResolver(
      client: o.session.plexClient,
      ratingKey: '101',
      version: version,
      mediaIndex: 0,
      playbackId: 'pb',
      profile: receiverDeviceProfile,
      forReceiver: true,
    );

    final stream = await resolver.resolve(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung.original,
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: '21',
      startAt: Duration.zero,
    );

    final url = Uri.parse(stream.url);
    expect(url.queryParameters['X-Plex-Token'], FakePlexServer.token);
    expect(url.queryParameters['subtitles'], 'none');
    expect(stream.headers, isEmpty);
  });

  test('receiver mode burns the chosen subtitle after selecting it on the part',
      () async {
    final o = open();
    final version = (await o.session.loadDetail()).versions.single;
    final resolver = PlexStreamResolver(
      client: o.session.plexClient,
      ratingKey: '101',
      version: version,
      mediaIndex: 0,
      playbackId: 'pb',
      profile: receiverDeviceProfile,
      forReceiver: true,
      burnSubtitleStreamId: '33',
    );

    final stream = await resolver.resolve(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung.original,
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: '21',
      startAt: Duration.zero,
    );

    final put = o.server.requests.firstWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/library/parts/21');
    expect(put.url.queryParameters['subtitleStreamID'], '33');
    expect(put.url.queryParameters['allParts'], '1');
    expect(Uri.parse(stream.url).queryParameters['subtitles'], 'burn');
  });

  test('local mode still keeps the token out of the URL', () async {
    final o = open();
    final version = (await o.session.loadDetail()).versions.single;
    final stream = await PlexStreamResolver(
      client: o.session.plexClient,
      ratingKey: '101',
      version: version,
      mediaIndex: 0,
      playbackId: 'pb',
    ).resolve(const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
        fileId: '21', startAt: Duration.zero);
    expect(stream.url, isNot(contains(FakePlexServer.token)));
    expect(stream.headers['X-Plex-Token'], FakePlexServer.token);
  });

  test('a Plex session can cast', () {
    expect(open().session.features, contains(PlaybackFeature.cast));
  });
}
