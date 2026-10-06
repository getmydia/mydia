import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mydia_test_source.dart';

void main() {
  Future<ProviderContainer> container(InMemorySourceStore store) async {
    final c = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    return c;
  }

  test('is false with no account stored', () async {
    final c = await container(InMemorySourceStore());
    expect(c.read(hasMydiaProvider), isFalse);
  });

  test('is true once a Mydia account is stored', () async {
    final store = InMemorySourceStore();
    await store.putAccount(testMydiaRecord());
    final c = await container(store);
    expect(c.read(hasMydiaProvider), isTrue);
    expect(c.read(sourcesProvider), [testMydiaSource]);
  });
}
