import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/all_servers/all_servers_banner.dart';

import '../../../domain/merged/fake_merged_source.dart';

void main() {
  final a = FakeMergedSource(fakeServer('a'));
  final b = FakeMergedSource(fakeServer('b'));

  Future<void> pump(WidgetTester tester, List<SourceId> unavailable) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourcesProvider.overrideWithValue([a.source, b.source]),
            allServersSourcesProvider.overrideWithValue([a, b]),
            allServersNeedSignInProvider.overrideWithValue(const []),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AllServersBanner(unavailable: unavailable, onRetry: () {}),
            ),
          ),
        ),
      );

  testWidgets('a different unavailable server shows the banner again',
      (tester) async {
    await pump(tester, [a.id]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('all-unavailable-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('all-unavailable-banner')), findsNothing);

    // Same length, different server.
    await pump(tester, [b.id]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);
  });

  testWidgets('a server no longer included is not named', (tester) async {
    await pump(tester, [const SourceId('gone:owner:s1')]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsNothing);
    expect(find.textContaining('gone'), findsNothing);
  });
}
