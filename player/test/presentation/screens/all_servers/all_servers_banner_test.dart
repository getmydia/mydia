import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/all_servers/all_servers_banner.dart';

void main() {
  testWidgets('a different unavailable server shows the banner again',
      (tester) async {
    Future<void> pump(List<SourceId> unavailable) => tester.pumpWidget(
          ProviderScope(
            overrides: [
              sourcesProvider.overrideWithValue(const []),
              allServersNeedSignInProvider.overrideWithValue(const []),
            ],
            child: MaterialApp(
              home: Scaffold(
                body:
                    AllServersBanner(unavailable: unavailable, onRetry: () {}),
              ),
            ),
          ),
        );

    await pump(const [SourceId('a')]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('all-unavailable-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('all-unavailable-banner')), findsNothing);

    // Same length, different server.
    await pump(const [SourceId('b')]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);
  });
}
