import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/load_content_fetchers.dart';

import '../sources/fake_media_source.dart';
import 'detail_harness.dart';

const _show =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.show, externalId: 'sh-1');

late WidgetRef _ref;

Future<void> _pump(WidgetTester tester, {required bool bound}) async {
  final source = ScriptedDetailSource(
    detailOf: (ref) => ItemDetail(
      summary: ItemSummary(
        ref: ref,
        title: 'Copper Weather',
        index: 3,
        parentIndex: 2,
      ),
      show: ref.kind == ItemKind.episode ? _show : null,
      versions: const [MediaVersion(id: 'file-9', container: 'mkv')],
    ),
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      boundSourceIdProvider.overrideWithValue(bound ? fakeSourceId : null),
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        _ref = ref;
        return const SizedBox();
      }),
    ),
  ));
}

void main() {
  testWidgets('with no bound source a fetch fails', (tester) async {
    await _pump(tester, bound: false);

    expect(fetchLoadContentMovie(_ref, 'm1'), throwsStateError);
    expect(fetchLoadContentEpisode(_ref, 'e1'), throwsStateError);
  });

  testWidgets('an episode maps its show, season and version', (tester) async {
    await _pump(tester, bound: true);

    final target = await fetchLoadContentEpisode(_ref, 'e1');

    expect(target.title, 'Copper Weather');
    expect(target.showId, 'sh-1');
    expect(target.seasonNumber, 2);
    expect(target.files.single.id, 'file-9');
  });

  testWidgets('a movie carries its title and files only', (tester) async {
    await _pump(tester, bound: true);

    final target = await fetchLoadContentMovie(_ref, 'm1');

    expect(target.title, 'Copper Weather');
    expect(target.showId, isNull);
    expect(target.files.single.id, 'file-9');
  });
}
