import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

Future<void> pumpLibrary(WidgetTester tester, FakeMediaSource fake) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
      // No artwork requests: a poster with a URL spins until the blocked
      // test HTTP client answers, which pumpAndSettle never outlasts.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: const MaterialApp(
      home: SourceLibraryScreen(library: FakeMediaSource.movies),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('loads the next page as the grid nears its end', (tester) async {
    final fake = FakeMediaSource(movieCount: 130);
    await pumpLibrary(tester, fake);
    expect(fake.browseCalls, hasLength(1));
    // The sort and filter chip row is also a Scrollable, and comes first.
    await tester.drag(
      find.descendant(
          of: find.byType(GridView), matching: find.byType(Scrollable)),
      const Offset(0, -20000),
    );
    await tester.pumpAndSettle();
    expect(fake.browseCalls.length, greaterThan(1));
    // A drag this long keeps loading until the end; the first follow-up
    // call resumes after the first page.
    expect(fake.browseCalls[1].$2?.value, '60');
  });

  testWidgets('sort and filter come from the library', (tester) async {
    final fake = FakeMediaSource();
    await pumpLibrary(tester, fake);
    await tester.tap(find.byKey(const Key('source-sort-added')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.sortId, 'added');
    await tester.tap(find.byKey(const Key('source-filter-unwatched')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.filterIds, {'unwatched'});
  });

  testWidgets('directional keys move between posters', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
    await pumpLibrary(tester, FakeMediaSource());

    final first = find.byKey(const ValueKey('source-poster-m1'));
    final second = find.byKey(const ValueKey('source-poster-m2'));
    // The nearest Focus above the MediaPoster is SourcePoster's
    // FocusHighlight.
    Focus.of(tester.element(
            find.descendant(of: first, matching: find.byType(MediaPoster))))
        .requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
          of: second, matching: find.byElementPredicate((e) => e == focused)),
      findsOneWidget,
    );
  });
}
