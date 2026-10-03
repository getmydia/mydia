import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/simple_playback_transport.dart';
import 'package:player/domain/models/quality_rung.dart';

class _Resolver implements StreamResolver {
  final ended = <String>[];
  var n = 0;

  @override
  Future<ResolvedStream> resolve(PlaybackPlan plan,
      {required String fileId, required Duration startAt}) async {
    n++;
    return ResolvedStream(
      url: 'https://fake.test/$n',
      headers: const {'X-Plex-Token': 'tok'},
      sessionId: plan is HlsPlan ? 's$n' : null,
    );
  }

  @override
  Future<void> end(String sessionId) async => ended.add(sessionId);
}

const _direct = DirectPlayPlan(reason: PlanReason.directPlayAccepted);
const _hls = HlsPlan(
  strategy: HlsStrategy.transcode,
  rung: QualityRung.original,
  adaptive: false,
  reason: PlanReason.fallbackFromFailure,
);

void main() {
  test('direct play seeks after opening; HLS is a full playlist', () async {
    final transport = SimplePlaybackTransport(resolver: _Resolver());
    final direct = await transport.open(_direct,
        fileId: 'f',
        startAt: Duration.zero,
        totalDuration: const Duration(minutes: 90));
    expect(direct.url, 'https://fake.test/1');
    expect(direct.headers, {'X-Plex-Token': 'tok'});
    expect(direct.seekOnOpen, isTrue);
    expect(direct.fullPlaylist, isFalse);
    expect(transport.sessionId, isNull);

    final hls = await transport.open(_hls, fileId: 'f', startAt: Duration.zero);
    expect(hls.fullPlaylist, isTrue);
    expect(hls.seekOnOpen, isTrue);
    expect(transport.sessionId, 's2');
  });

  test('replacing a source ends the old session once frames flow', () async {
    final resolver = _Resolver();
    final transport = SimplePlaybackTransport(resolver: resolver);
    await transport.open(_hls, fileId: 'f', startAt: Duration.zero);
    final positions = StreamController<Duration>();
    final replaced = transport.replaceSource(
      _hls,
      fileId: 'f',
      realPosition: const Duration(minutes: 5),
      attach: (_) async => positions.stream,
    );
    await Future<void>.delayed(Duration.zero);
    expect(resolver.ended, isEmpty);
    positions
      ..add(const Duration(minutes: 5))
      ..add(const Duration(minutes: 5, seconds: 1));
    await replaced;
    expect(resolver.ended, ['s1']);
    expect(transport.sessionId, 's2');
    await positions.close();
  });

  test('ending ends every owned session once', () async {
    final resolver = _Resolver();
    final transport = SimplePlaybackTransport(resolver: resolver);
    await transport.open(_hls, fileId: 'f', startAt: Duration.zero);
    await transport.endSession();
    await transport.endSession();
    expect(resolver.ended, ['s1']);
  });
}
