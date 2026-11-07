import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
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

/// [settle] false leaves a search in flight: its progress bar never settles.
Future<void> _pump(WidgetTester tester, _Editing editing,
    {bool settle = true}) async {
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
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

  test('fix_match_offered_for_a_source_that_edits_matches', () {
    expect(canFixMatch(_EditingSource(), _ref), isTrue);
    expect(canFixMatch(_EditingSource(editable: false), _ref), isFalse);
  });

  testWidgets('an older search answering last is dropped', (tester) async {
    final editing = _HeldEditing();
    await _pump(tester, editing, settle: false);
    expect(editing.pending, hasLength(1));

    await tester.enterText(find.byKey(const Key('fix-match-title')), 'Newer');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(editing.pending, hasLength(2));

    editing.pending[1]
        .complete(const [TmdbCandidate(id: 22, title: 'Newer Film')]);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    editing.pending[0]
        .complete(const [TmdbCandidate(id: 21, title: 'Older Film')]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('fix-match-result-22')), findsOneWidget);
    expect(find.byKey(const ValueKey('fix-match-result-21')), findsNothing);
  });

  testWidgets('an older search cannot end a newer one\'s wait', (tester) async {
    final editing = _HeldEditing();
    await _pump(tester, editing, settle: false);
    await tester.enterText(find.byKey(const Key('fix-match-title')), 'Newer');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    editing.pending[0].complete(const []);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    editing.pending[1].complete(const []);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a match that moves the item closes its detail page',
      (tester) async {
    final source = _EditingSource();
    await tester.pumpWidget(ProviderScope(
      overrides: [mediaSourceProvider(fakeSourceId).overrideWithValue(source)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            key: const Key('open-detail'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    key: const Key('fix'),
                    onPressed: fixMatchAction(context, ref, _ref, 'Old'),
                    child: const Text('detail page'),
                  ),
                ),
              ),
            )),
            child: const Text('home'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-detail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fix')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fix-match-result-11')));
    await tester.pumpAndSettle();

    expect(source.sets.single?.id, 11);
    expect(find.text('detail page'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a match that keeps the item leaves its detail page open',
      (tester) async {
    final source = _EditingSource(itemSurvives: true);
    await tester.pumpWidget(ProviderScope(
      overrides: [mediaSourceProvider(fakeSourceId).overrideWithValue(source)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              key: const Key('fix'),
              onPressed: fixMatchAction(context, ref, _ref, 'Old'),
              child: const Text('detail page'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('fix')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fix-match-result-11')));
    await tester.pumpAndSettle();
    expect(find.text('detail page'), findsOneWidget);
  });
}

/// Holds each search until the test completes it.
class _HeldEditing extends _Editing {
  final pending = <Completer<List<TmdbCandidate>>>[];

  @override
  Future<List<TmdbCandidate>> searchMatches(
    ItemRef ref,
    String query, {
    int? year,
  }) {
    final c = Completer<List<TmdbCandidate>>();
    pending.add(c);
    return c.future;
  }
}

/// A source that edits matches; once a match is set, its old item is gone
/// unless [itemSurvives].
class _EditingSource extends FakeMediaSource implements MatchEditing {
  _EditingSource({this.editable = true, this.itemSurvives = false});

  final bool editable;
  final bool itemSurvives;
  final sets = <TmdbCandidate?>[];

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.matchEditing};

  @override
  bool canEditMatch(ItemRef ref) => editable;

  @override
  Future<List<TmdbCandidate>> searchMatches(
    ItemRef ref,
    String query, {
    int? year,
  }) async =>
      const [TmdbCandidate(id: 11, title: 'Invented Film', year: 1999)];

  @override
  Future<void> setMatch(ItemRef ref, TmdbCandidate? choice) async =>
      sets.add(choice);

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    if (sets.isNotEmpty && !itemSurvives) {
      throw const SourceException.notFound();
    }
    return super.item(const ItemRef(
        sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm1'));
  }
}
