import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/subtitle_search_results.dart';

void main() {
  Future<void> pump(WidgetTester tester, SubtitleCandidate candidate) {
    return tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SubtitleSearchResults(
          results: [candidate],
          providers: const [],
          languages: const ['en'],
          onSelect: (_) {},
        ),
      ),
    ));
  }

  SubtitleCandidate candidate({required String language, String? release}) =>
      SubtitleCandidate(
        token: 't1',
        language: language,
        releaseName: release,
        format: 'srt',
        hearingImpaired: false,
        hashMatch: false,
        score: 1,
        providerName: 'Provider',
      );

  testWidgets('title falls back to the code for an unknown language',
      (tester) async {
    await pump(tester, candidate(language: 'zz-unknown'));

    final title = tester.widget<ListTile>(find.byType(ListTile)).title as Text;
    // languageName upper-cases a code it does not recognise.
    expect(title.data, 'ZZ-UNKNOWN');
  });

  testWidgets('title prefers the release name when there is one',
      (tester) async {
    await pump(tester, candidate(language: 'zz-unknown', release: 'Rel.1080p'));

    final title = tester.widget<ListTile>(find.byType(ListTile)).title as Text;
    expect(title.data, 'Rel.1080p');
  });
}
