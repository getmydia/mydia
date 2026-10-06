import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';

import '../sources/mydia/mydia_account_harness.dart';
import '../sources/source_factories_test.dart' show atticRecord;

const _ma = MydiaCredentials(
    instanceId: 'a', accessToken: 'ta', serverUrl: 'https://a.example.test');
const _mb = MydiaCredentials(
    instanceId: 'b', accessToken: 'tb', serverUrl: 'https://b.example.test');

void main() {
  Future<void> settle(ProviderContainer container) async {
    await container.read(sourceRecordsProvider.future);
    await container.read(legacyInstanceIdProvider.future);
  }

  SourceId idOf(String instanceId) => mydiaSourceIdOf(mydiaRecord(instanceId));

  test('the stored legacy id resolves to that account\'s source', () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('mb');
    await settle(h.container);
    expect(h.container.read(legacyMydiaSourceIdProvider), idOf('b'));
  });

  test('a removed legacy account resolves to the only instance left', () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('ma');
    await settle(h.container);
    h.container.listen(legacyMydiaSourceIdProvider, (_, __) {});
    expect(h.container.read(legacyMydiaSourceIdProvider), idOf('a'));

    await h.container.read(sourceRecordsProvider.notifier).removeAccount('ma');
    expect(h.container.read(legacyMydiaSourceIdProvider), idOf('b'));
  });

  test('an unusable legacy id with two accounts left resolves to nothing',
      () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('mz');
    await settle(h.container);
    expect(h.container.read(legacyMydiaSourceIdProvider), isNull);
  });

  test('never resolves another account while the legacy marker loads',
      () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.setLegacyInstanceId('mb');
    final seen = <SourceId?>[];
    h.container.listen(
      legacyMydiaSourceIdProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    await settle(h.container);
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNot(contains(idOf('a'))));
    expect(h.container.read(legacyMydiaSourceIdProvider), idOf('b'));
  });

  test('no legacy id: the only Mydia instance', () async {
    final h = await mydiaAccountHarness({'a': _ma});
    addTearDown(h.container.dispose);
    await settle(h.container);
    expect(h.container.read(legacyMydiaSourceIdProvider), idOf('a'));
  });

  test('no legacy id: nothing, with several Mydia accounts', () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await settle(h.container);
    expect(h.container.read(legacyMydiaSourceIdProvider), isNull);
  });

  test('a non-Mydia account with the legacy id is not picked', () async {
    final h = await mydiaAccountHarness({'a': _ma, 'b': _mb});
    addTearDown(h.container.dispose);
    await h.store.putAccount(atticRecord);
    await h.store.setLegacyInstanceId(atticRecord.account.id);
    await settle(h.container);
    expect(h.container.read(legacyMydiaSourceIdProvider), isNull);
  });
}
