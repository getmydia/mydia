import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/sources_providers.dart';

import '../source_factories_test.dart' show atticRecord;
import 'bound_mydia_harness.dart';

const _ma = MydiaCredentials(
    instanceId: 'a', accessToken: 'ta', serverUrl: 'https://a.example.test');
const _mb = MydiaCredentials(
    instanceId: 'b', accessToken: 'tb', serverUrl: 'https://b.example.test');

void main() {
  Future<void> settle(ProviderContainer container) async {
    await container.read(sourceRecordsProvider.future);
    await container.read(legacyInstanceIdProvider.future);
  }

  test('no Mydia account: null', () async {
    final h = await boundMydiaHarness({});
    addTearDown(h.container.dispose);
    await settle(h.container);
    expect(h.container.read(boundMydiaProvider), isNull);
    expect(h.container.read(boundMydiaClientProvider), isNull);
  });

  test('legacy instance wins while it exists', () async {
    final h = await boundMydiaHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('mb');
    await settle(h.container);
    expect(h.container.read(boundMydiaProvider)?.source.account.id, 'mb');
  });

  test('falls back to the first Mydia account added', () async {
    final h = await boundMydiaHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await settle(h.container);
    expect(h.container.read(boundMydiaProvider)?.source.account.id, 'ma');
  });

  test('removing the bound instance rebinds to the other', () async {
    final h = await boundMydiaHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('ma');
    await settle(h.container);
    expect(h.container.read(boundMydiaProvider)?.source.account.id, 'ma');
    h.container.listen(boundMydiaProvider, (_, __) {});
    await h.container.read(sourceRecordsProvider.notifier).removeAccount('ma');
    expect(h.container.read(boundMydiaProvider)?.source.account.id, 'mb');
  });

  test('Plex-only: null', () async {
    final h = await boundMydiaHarness({});
    addTearDown(h.container.dispose);
    await h.store.putAccount(atticRecord);
    await settle(h.container);
    expect(h.container.read(boundMydiaProvider), isNull);
  });

  test('the bound client reads the bound credentials', () async {
    final h = await boundMydiaHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('mb');
    await settle(h.container);
    final c = await h.container.read(boundMydiaClientProvider)!.credentials();
    expect(c.accessToken, 'tb');
  });
}
