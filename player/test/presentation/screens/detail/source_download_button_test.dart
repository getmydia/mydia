import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/toast_harness.dart';
import '../sources/fake_media_source.dart';
import 'download_fakes.dart';

const _movie =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm1');

Future<void> _pump(WidgetTester tester, FakeMediaSource source) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      downloadManagerProvider
          .overrideWith((ref) async => EmptyDownloadService()),
      isItemDownloadedProvider(_movie).overrideWith((ref) => false),
    ],
    child: const MaterialApp(
      builder: toastLayerBuilder,
      home: MovieDetailScreen.target(target: SourceTarget(_movie)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a downloadable source shows the download action and confirms',
      (tester) async {
    await _pump(tester, DownloadableFakeSource());
    expect(find.byType(MovieDetailScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('download-confirm-original')), findsOneWidget);
  });

  testWidgets('a source that cannot download has no download action',
      (tester) async {
    await _pump(tester, FakeMediaSource());
    expect(find.byType(MovieDetailScreen), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });
}
