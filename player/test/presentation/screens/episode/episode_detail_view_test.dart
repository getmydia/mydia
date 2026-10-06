import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/episode/episode_detail_screen.dart';

import '../detail/detail_harness.dart';
import '../sources/fake_media_source.dart';

const _ref =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.episode, externalId: 'e-1');
const _show =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.show, externalId: 's-1');

ItemDetail _episode(ItemRef ref, {required bool withFile}) => ItemDetail(
      summary: ItemSummary(
        ref: ref,
        title: 'Copper Weather',
        showTitle: 'Invented Series',
        index: 3,
        parentIndex: 1,
        durationSeconds: 2820,
        airDate: '2024-03-02',
        defaultVersionId: withFile ? 'f-1' : null,
      ),
      overview: 'The crew waits out a storm of metal dust.',
      show: _show,
      versions: [
        if (withFile)
          const MediaVersion(id: 'f-1', container: 'mkv', height: 1080),
      ],
    );

Future<void> _pumpScreen(WidgetTester tester, {bool withFile = false}) {
  final source = ScriptedDetailSource(
    detailOf: (ref) => _episode(ref, withFile: withFile),
  );
  return pumpDetailScreen(
    tester,
    const EpisodeDetailScreen.target(target: SourceTarget(_ref)),
    [source],
    size: const Size(400, 900),
    routes: [
      GoRoute(
        path: '/s/:sourceId/show/:id',
        builder: (context, state) => const Text('show page'),
      ),
    ],
  );
}

void main() {
  testWidgets('the show link opens the show', (tester) async {
    await _pumpScreen(tester);
    await tester.tap(find.text('Invented Series'));
    await tester.pumpAndSettle();
    expect(find.text('show page'), findsOneWidget);
  });

  // The download branch (shown disabled for a file-less episode) needs
  // `isDownloadSupported`, which is false on the test platform, so it cannot
  // be exercised here. Media info is the file-dependent control we can check.
  testWidgets('media info shows only for an episode with files',
      (tester) async {
    await _pumpScreen(tester, withFile: true);
    expect(find.byKey(const Key('episode-media-info')), findsOneWidget);
  });

  testWidgets('media info is absent for a file-less episode', (tester) async {
    await _pumpScreen(tester);
    expect(find.byKey(const Key('episode-media-info')), findsNothing);
  });

  testWidgets('shows the episode code and title', (tester) async {
    await _pumpScreen(tester);
    expect(find.text('S01E03'), findsOneWidget);
    expect(find.text('Copper Weather'), findsOneWidget);
  });
}
