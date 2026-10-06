import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/queue_player_screen.dart';

import '../../../core/sources/mydia/fake_mydia_transport.dart';
import '../../../core/sources/mydia/mydia_source_test.dart' show guest, sid;

MydiaSource _mydiaSource() => MydiaSource(
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
    );

/// A two-item queue whose files are `offline`, so mounting the player needs
/// no server answer to settle.
String _queueParam() => base64Url.encode(utf8.encode(jsonEncode([
      {
        'type': 'movie',
        'id': 'm1',
        'file_id': 'offline',
        'title': 'The Long Aurora',
      },
      {
        'type': 'episode',
        'id': 'e1',
        'file_id': 'offline',
        'title': 'Second Light',
      },
    ])));

Future<void> _pump(WidgetTester tester, {required bool withSource}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      localProxyServiceProvider
          .overrideWithValue(LocalProxyService.forTesting()),
      legacyMydiaSourceIdProvider.overrideWithValue(withSource ? sid : null),
      if (withSource)
        mediaSourceProvider(sid).overrideWithValue(_mydiaSource()),
    ],
    child: MaterialApp(home: QueuePlayerScreen(itemsParam: _queueParam())),
  ));
}

void main() {
  testWidgets('the queue plays from the Mydia instance, item by item',
      (tester) async {
    await _pump(tester, withSource: true);

    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(screen.session.item.sourceId, sid);
    expect(screen.session.item.externalId, 'm1');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with no Mydia instance the queue says it cannot play',
      (tester) async {
    await _pump(tester, withSource: false);

    expect(find.byKey(const Key('queue-player-unavailable')), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
  });
}
