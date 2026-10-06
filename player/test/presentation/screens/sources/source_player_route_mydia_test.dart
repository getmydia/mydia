import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/sources/source_player_route.dart';

import '../../../core/sources/mydia/fake_mydia_transport.dart';
import '../../../core/sources/mydia/mydia_source_test.dart' show guest, sid;

MydiaSource _mydiaSource(LocalProxyService proxy) => MydiaSource(
      source: guest,
      client: MydiaClient(
        transport: FakeMydiaTransport(),
        load: () async => const MydiaCredentials(
          instanceId: 'inst-1',
          accessToken: 'access',
          serverUrl: 'https://lake.example',
        ),
        save: (_) async {},
        onUnauthorized: () {},
      ),
      proxy: () => proxy,
    );

void main() {
  Future<PlayerScreen> pump(
    WidgetTester tester, {
    required SourceId? bound,
  }) async {
    final proxy = LocalProxyService.forTesting();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        boundSourceIdProvider.overrideWithValue(bound),
        localProxyServiceProvider.overrideWithValue(proxy),
        mediaSourceProvider(sid).overrideWithValue(_mydiaSource(proxy)),
      ],
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: sid,
          itemId: 'm1',
          uri: Uri.parse('/s/x/player/m1?kind=movie&fileId=offline'),
        ),
      ),
    ));
    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    await tester.pumpWidget(const SizedBox());
    return screen;
  }

  testWidgets('the bound instance plays through the screen\'s own session',
      (tester) async {
    final screen = await pump(tester, bound: sid);
    // Null makes the screen build MydiaPlaybackSession (all features), the
    // session `/player/...` used before items moved to this route. The
    // `offline` file id reaches it unchanged.
    expect(screen.session, isNull);
    expect(screen.fileId, 'offline');
  });

  testWidgets('another Mydia instance gets the same session with every feature',
      (tester) async {
    final screen = await pump(tester, bound: const SourceId('other'));
    final session = screen.session;
    expect(session, isA<MydiaPlaybackSession>());
    expect(session!.features, PlaybackFeature.values.toSet());
  });
}
