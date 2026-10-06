import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

/// Search answers only when the test completes the matching request.
class _ControlledSearchSource extends FakeMediaSource {
  final requests = <(String, Completer<List<ItemSummary>>)>[];

  @override
  Future<List<ItemSummary>> search(String query) {
    final completer = Completer<List<ItemSummary>>();
    requests.add((query, completer));
    return completer.future;
  }
}

class _NoSearchSource extends FakeMediaSource {
  @override
  Set<SourceCapability> get capabilities => const {};

  @override
  T? as<T extends Object>() => null;
}

Future<void> pumpSearch(WidgetTester tester, FakeMediaSource fake) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
      // No artwork requests: a URL keeps a spinner running and pumpAndSettle never settles.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: const MaterialApp(home: SourceSearchScreen(sourceId: fakeSourceId)),
  ));
}

class _MixedSearchSource extends FakeMediaSource {
  @override
  Future<List<ItemSummary>> search(String query) async =>
      [fakeMovie(1), fakeShow, fakeEpisode(1)];
}

void main() {
  testWidgets('kind chips narrow the results client-side', (tester) async {
    await pumpSearch(tester, _MixedSearchSource());
    await tester.enterText(
        find.byKey(const Key('source-search-field')), 'invented');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-poster-m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-poster-s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-poster-e1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('source-search-kind-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-poster-m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-poster-s1')), findsNothing);
    expect(find.byKey(const ValueKey('source-poster-e1')), findsNothing);

    await tester.tap(find.byKey(const Key('source-search-kind-episodes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-poster-e1')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-poster-m1')), findsNothing);

    await tester.tap(find.byKey(const Key('source-search-kind-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-poster-s1')), findsOneWidget);
  });

  testWidgets('initialQuery fills the box and searches', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: const MaterialApp(
        home:
            SourceSearchScreen(sourceId: fakeSourceId, initialQuery: 'film 2'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('source-search-field')))
            .controller
            ?.text,
        'film 2');
    expect(find.text('Invented Film 2'), findsOneWidget);
  });

  testWidgets('clearing the box wins over a search still in flight',
      (tester) async {
    final fake = _ControlledSearchSource();
    await pumpSearch(tester, fake);
    final field = find.byKey(const Key('source-search-field'));
    await tester.enterText(field, 'film');
    await tester.pump(const Duration(milliseconds: 500));
    expect(fake.requests, hasLength(1));

    await tester.enterText(field, '');
    await tester.pump();
    fake.requests.single.$2.complete([fakeMovie(1)]);
    await tester.pumpAndSettle();
    expect(find.text('Invented Film 1'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('retry runs the last query again', (tester) async {
    final fake = _ControlledSearchSource();
    await pumpSearch(tester, fake);
    await tester.enterText(
        find.byKey(const Key('source-search-field')), 'film');
    await tester.pump(const Duration(milliseconds: 500));
    fake.requests.single.$2.completeError(const SourceException.unreachable());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(fake.requests, hasLength(2));
    expect(fake.requests.last.$1, 'film');
    fake.requests.last.$2.complete([fakeMovie(1)]);
    await tester.pumpAndSettle();
    expect(find.text('Invented Film 1'), findsOneWidget);
  });

  testWidgets('a source without search says so', (tester) async {
    await pumpSearch(tester, _NoSearchSource());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-search-unsupported')), findsOneWidget);
    expect(find.byKey(const Key('source-search-field')), findsNothing);
  });

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
