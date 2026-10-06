import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/load_content_fetchers.dart';

import '../sources/fake_media_source.dart';
import 'detail_harness.dart';

late WidgetRef _ref;

Future<void> _pump(WidgetTester tester) async {
  final source = ScriptedDetailSource(
    detailOf: (ref) => ItemDetail(
      summary: ItemSummary(ref: ref, title: 'Copper Weather'),
      versions: const [MediaVersion(id: 'file-9', container: 'mkv')],
    ),
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
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
  testWidgets('reads the item from the source its ref names', (tester) async {
    await _pump(tester);

    final detail = await fetchLoadContentItem(
      _ref,
      const ItemRef(
          sourceId: fakeSourceId, kind: ItemKind.episode, externalId: 'e1'),
    );

    expect(detail.summary.title, 'Copper Weather');
    expect(detail.versions.single.id, 'file-9');
  });
}
