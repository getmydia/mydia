import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

void main() {
  testWidgets('searches after typing settles', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
        // No artwork requests: a URL keeps a spinner running and pumpAndSettle never settles.
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child:
          const MaterialApp(home: SourceSearchScreen(sourceId: fakeSourceId)),
    ));
    await tester.enterText(
        find.byKey(const Key('source-search-field')), 'film 2');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Invented Film 2'), findsNothing, reason: 'debounced');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Invented Film 2'), findsOneWidget);
  });
}
