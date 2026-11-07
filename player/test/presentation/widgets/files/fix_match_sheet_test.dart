import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/files/fix_match_sheet.dart';

import '../../screens/sources/fake_media_source.dart';

class _Editing implements MatchEditing {
  final searches = <(String, int?)>[];
  final sets = <TmdbCandidate?>[];

  @override
  bool canEditMatch(ItemRef ref) => true;

  @override
  Future<List<TmdbCandidate>> searchMatches(
    ItemRef ref,
    String query, {
    int? year,
  }) async {
    searches.add((query, year));
    return const [
      TmdbCandidate(id: 11, title: 'Invented Film', year: 1999),
      TmdbCandidate(id: 12, title: 'Invented Film Two', year: 2004),
    ];
  }

  @override
  Future<void> setMatch(ItemRef ref, TmdbCandidate? choice) async =>
      sets.add(choice);
}

const _ref =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'tmdb-1');

Future<void> _pump(WidgetTester tester, _Editing editing) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => FixMatchSheet(
                editing: editing,
                item: _ref,
                initialTitle: 'Invented Film',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fix_match_pins_the_chosen_result', (tester) async {
    final editing = _Editing();
    await _pump(tester, editing);
    expect(editing.searches.single, ('Invented Film', null));

    await tester.enterText(find.byKey(const Key('fix-match-year')), '2004');
    await tester.tap(find.byKey(const Key('fix-match-search')));
    await tester.pumpAndSettle();
    expect(editing.searches.last, ('Invented Film', 2004));

    await tester.tap(find.byKey(const ValueKey('fix-match-result-12')));
    await tester.pumpAndSettle();
    expect(editing.sets.single?.id, 12);
    expect(find.byType(FixMatchSheet), findsNothing);
  });

  testWidgets('unmatch_calls_set_match_with_null', (tester) async {
    final editing = _Editing();
    await _pump(tester, editing);
    await tester.tap(find.byKey(const Key('fix-match-unmatch')));
    await tester.pumpAndSettle();
    expect(editing.sets, [null]);
    expect(find.byType(FixMatchSheet), findsNothing);
  });

  test('fix_match_hidden_for_sources_without_the_capability', () {
    expect(canFixMatch(FakeMediaSource(), _ref), isFalse);
    expect(canFixMatch(null, _ref), isFalse);
  });
}
