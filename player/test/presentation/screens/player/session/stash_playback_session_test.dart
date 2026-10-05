import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/session/stash_playback_session.dart';

import '../../../../core/sources/stash/fake_stash_server.dart';
import '../../../../core/sources/stash/stash_media_source_test.dart' show build;

void main() {
  const scene = ItemRef(
      sourceId: SourceId('st1:owner:main'),
      kind: ItemKind.video,
      externalId: '2');

  ({StashPlaybackSession session, FakeStashServer server}) open() {
    final b = build();
    return (
      session:
          StashPlaybackSession(source: b.source, item: scene, fileId: '92'),
      server: b.server,
    );
  }

  test('play duration is the playing time since the previous report', () async {
    var now = DateTime(2026, 1, 1, 12);
    final b = build();
    final reporter = StashProgressReporter(
        client: b.source.client, sceneId: '2', clock: () => now);
    Future<double> report({required bool paused}) async {
      await reporter.sendProgress(
          positionSeconds: 10, durationSeconds: 1200, paused: paused);
      return b.server.operations.last.$2['playDuration'] as double;
    }

    expect(await report(paused: false), 0.0); // first report
    now = now.add(const Duration(seconds: 10));
    expect(await report(paused: false), 10.0); // periodic tick
    now = now.add(const Duration(seconds: 4));
    expect(await report(paused: true), 4.0); // pause: playing until now
    now = now.add(const Duration(seconds: 30));
    expect(await report(paused: false), 0.0); // resume: paused through it
    now = now.add(const Duration(seconds: 2));
    expect(await report(paused: false), 2.0); // seek while playing
  });

  test('maps heights to Stash resolutions', () {
    expect(stashResolutionFor(null), 'ORIGINAL');
    expect(stashResolutionFor(240), 'LOW');
    expect(stashResolutionFor(480), 'STANDARD');
    expect(stashResolutionFor(720), 'STANDARD_HD');
    expect(stashResolutionFor(1080), 'FULL_HD');
    expect(stashResolutionFor(2160), 'FOUR_K');
  });

  test('offers direct play and transcode, no copy', () async {
    final offer = (await open().session.candidates(CandidateScope.file)).offer!;
    expect(
        offer.candidates.map((c) => c.strategy), ['DIRECT_PLAY', 'TRANSCODE']);
    expect(offer.fileId, '92');
  });

  test('saved progress comes from the resume time', () async {
    final detail = (await open().session.detail())!;
    expect(detail.savedPositionSeconds, 300);
    expect(detail.serverSubtitleTracks!.single.language, 'en');
  });

  test('streams with the key in a header and never in the URL', () async {
    final o = open();
    final setup = ((await o.session.prepareStreaming(
            owner: Object(),
            onProgress: (_) {},
            isCurrent: () => true)) as StreamingReady)
        .setup;
    final transport = setup.createTransport(relayed: false);
    final direct = await transport.open(
      const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
      fileId: '92',
      startAt: Duration.zero,
    );
    expect(direct.url, 'http://192.168.1.20:9999/scene/2/stream');
    expect(direct.headers['ApiKey'], FakeStashServer.apiKey);

    final hls = await transport.open(
      const HlsPlan(
        strategy: HlsStrategy.transcode,
        rung: QualityRung(label: '720p', height: 720),
        adaptive: false,
        reason: PlanReason.fallbackFromFailure,
      ),
      fileId: '92',
      startAt: Duration.zero,
    );
    expect(hls.url,
        'http://192.168.1.20:9999/scene/2/stream.m3u8?resolution=STANDARD_HD');
    expect(hls.url, isNot(contains('apikey')));
  });

  test('progress saves activity; watched adds a play', () async {
    final o = open();
    final reporter = ((await o.session.prepareStreaming(
            owner: Object(),
            onProgress: (_) {},
            isCurrent: () => true)) as StreamingReady)
        .setup
        .progress as StashProgressReporter;
    await reporter.sendProgress(
        positionSeconds: 90, durationSeconds: 1200, paused: false);
    final (name, vars) = o.server.operations.last;
    expect(name, 'SaveActivity');
    expect(vars['id'], '2');
    expect(vars['resume_time'], 90.0);
    await reporter.sendWatched();
    expect(o.server.operations.last.$1, 'AddPlay');
  });

  test('receiver mode puts apikey on the direct stream', () async {
    final o = open();
    final stream = await StashStreamResolver(
      client: o.session.stashClient,
      sceneId: '2',
      forReceiver: true,
    ).resolve(const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
        fileId: '92', startAt: Duration.zero);

    final url = Uri.parse(stream.url);
    expect(url.path, '/scene/2/stream');
    expect(url.queryParameters['apikey'], FakeStashServer.apiKey);
    expect(stream.headers, isEmpty);
  });

  test('receiver mode keeps the resolution on the HLS stream', () async {
    final o = open();
    final stream = await StashStreamResolver(
      client: o.session.stashClient,
      sceneId: '2',
      forReceiver: true,
    ).resolve(
        const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.fallbackFromFailure,
        ),
        fileId: '92',
        startAt: Duration.zero);

    final url = Uri.parse(stream.url);
    expect(url.path, '/scene/2/stream.m3u8');
    expect(url.queryParameters['resolution'], 'ORIGINAL');
    expect(url.queryParameters['apikey'], FakeStashServer.apiKey);
  });
}
