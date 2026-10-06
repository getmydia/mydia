import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/detail_similar_rail.dart';
import 'package:player/presentation/screens/detail/source_detail_controllers.dart';
import 'package:player/presentation/screens/sources/source_poster_row.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../sources/fake_media_source.dart';

final _showTarget = SourceTarget(fakeShow.ref);
final _movieTarget = SourceTarget(fakeMovie(1).ref);

Future<void> _pump(WidgetTester tester, Widget rail, ItemRef item) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sourceSimilarProvider(item)
          .overrideWith((_) => Stream.value([fakeMovie(2), fakeMovie(3)])),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child:
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: rail))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a show starts collapsed under its old title and opens on tap',
      (tester) async {
    await _pump(
      tester,
      DetailSimilarRail(
          show: ShowView(target: _showTarget, title: 'Invented Series')),
      fakeShow.ref,
    );

    expect(find.text('Similar in your library'), findsOneWidget);
    expect(find.byKey(DetailSimilarRail.disclosureKey), findsOneWidget);
    expect(find.byType(SourcePosterRow), findsNothing);

    await tester.tap(find.text('Similar in your library'));
    await tester.pumpAndSettle();
    expect(find.byType(SourcePosterRow), findsOneWidget);
    expect(find.text('Invented Film 2'), findsOneWidget);

    await tester.tap(find.text('Similar in your library'));
    await tester.pumpAndSettle();
    expect(find.byType(SourcePosterRow), findsNothing);
  });

  testWidgets('a movie row is open with no disclosure', (tester) async {
    await _pump(
      tester,
      DetailSimilarRail(
          movie: MovieView(target: _movieTarget, title: 'Invented Film 1')),
      fakeMovie(1).ref,
    );

    expect(find.byType(SourcePosterRow), findsOneWidget);
    expect(find.byKey(DetailSimilarRail.disclosureKey), findsNothing);
  });
}
