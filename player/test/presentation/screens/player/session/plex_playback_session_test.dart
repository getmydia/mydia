import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/quality_rung.dart';
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
}
