import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/presentation/screens/show/show_bulk_download_button.dart';
import 'package:player/presentation/screens/show/show_season_section.dart';

import '../sources/fake_media_source.dart';

ShowView _show({Set<DetailFeature> features = const {}}) => ShowView(
      target: SourceTarget(fakeShow.ref),
      title: 'Invented Series',
      seasons: [SeasonView(number: 1, target: SourceTarget(fakeSeason.ref))],
      features: features,
    );

Future<void> _pump(WidgetTester tester, ShowView show) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(body: ShowSeasonSection(show: show)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a source show with season download gets the source button',
      (tester) async {
    await _pump(tester, _show(features: {DetailFeature.seasonDownload}));
    expect(find.byKey(const Key('source-season-download')), findsOneWidget);
    expect(find.byType(ShowBulkDownloadButton), findsNothing);
  });

  testWidgets('without the feature there is no download button',
      (tester) async {
    await _pump(tester, _show());
    expect(find.byKey(const Key('source-season-download')), findsNothing);
  });
}
