import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/detail/play_item.dart';

import '../../../test_utils/toast_harness.dart';
import '../sources/fake_media_source.dart';

/// Pumps one button that plays [item] from [fake]; answers what was pushed.
Future<List<String>> _pump(
    WidgetTester tester, FakeMediaSource fake, ItemRef item) async {
  final pushed = <String>[];
  Widget record(BuildContext _, GoRouterState s) {
    pushed.add(s.uri.toString());
    return const SizedBox();
  }

  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => Consumer(
        builder: (context, ref, _) => TextButton(
          key: const Key('play'),
          onPressed: () => playItem(context, ref, item),
          child: const Text('Play'),
        ),
      ),
    ),
    GoRoute(path: '/s/:id/player/:item', builder: record),
    GoRoute(path: '/s/:id/show/:item', builder: record),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [mediaSourceProvider(fakeSourceId).overrideWithValue(fake)],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.tap(find.byKey(const Key('play')));
  await tester.pumpAndSettle();
  return pushed;
}

void main() {
  testWidgets('an episode plays its best version', (tester) async {
    final pushed = await _pump(tester, FakeDetailSource(), fakeEpisode(3).ref);
    final uri = Uri.parse(pushed.single);
    expect(uri.path, '/s/acc1:owner:aa11/player/e3');
    expect(uri.queryParameters['fileId'], 'part-1');
  });

  testWidgets('a show plays its next-up episode', (tester) async {
    final pushed = await _pump(
        tester, FakeDetailSource(nextUpEpisode: fakeEpisode(4)), fakeShow.ref);
    expect(Uri.parse(pushed.single).path, '/s/acc1:owner:aa11/player/e4');
  });

  testWidgets('a show without next up opens the show', (tester) async {
    final pushed = await _pump(tester, FakeMediaSource(), fakeShow.ref);
    expect(pushed.single, '/s/acc1:owner:aa11/show/s1');
  });

  testWidgets('a failed fetch says why and goes nowhere', (tester) async {
    final fake = FakeDetailSource()
      ..itemError = const SourceException.unreachable();
    final pushed = await _pump(tester, fake, fakeEpisode(3).ref);
    expect(pushed, isEmpty);
    expect(find.text(const SourceException.unreachable().viewerMessage),
        findsOneWidget);
  });
}
