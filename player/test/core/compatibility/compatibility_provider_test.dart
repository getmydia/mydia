import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/compatibility/compatibility_provider.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/graphql/graphql_provider.dart';

import '../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> okResponse({
  String version = '0.9.0',
  String min = '0.9.0',
  String recommended = '0.9.0',
}) =>
    {
      '__typename': 'RootQueryType',
      'serverCompatibility': {
        '__typename': 'ServerCompatibility',
        'version': version,
        'minPlayerVersion': min,
        'recommendedPlayerVersion': recommended,
      },
    };

var _boxCounter = 0;

/// A fresh in-memory Hive box, one per call.
///
/// Two things matter here. The `bytes:` argument keeps the box in memory: a
/// disk-backed box hangs the suite for about ten minutes. And the name must be
/// unique per call, because `Hive.openBox` returns the already-open instance
/// for a repeated name, which would leak dismissal keys between tests and make
/// the isEmpty assertions pass or fail for the wrong reason.
Future<Box<bool>> memoryBox() =>
    Hive.openBox<bool>('compat-test-${_boxCounter++}', bytes: Uint8List(0));

ProviderContainer harness({
  required String playerVersion,
  required Object response,
  required Box<bool> box,
}) {
  final container = ProviderContainer(
    overrides: [
      graphqlClientProvider
          .overrideWithValue(stubClient(StubLink.responses([response]))),
      playerVersionProvider.overrideWith((ref) async => playerVersion),
      compatibilityDismissalBoxProvider.overrideWith((ref) async => box),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(() {
    Hive.init('./.dart_tool/compat_test');
  });

  test('a matching pair produces no banner', () async {
    final box = await memoryBox();
    final container = harness(
      playerVersion: '0.9.0',
      response: okResponse(),
      box: box,
    );

    final state = await container.read(compatibilityProvider.future);

    expect(state.verdict, CompatibilityVerdict.compatible);
    expect(state.showBanner, isFalse);
  });

  test('an old player against a new server requires an update', () async {
    final box = await memoryBox();
    final container = harness(
      playerVersion: '0.8.0',
      response: okResponse(version: '0.9.0', min: '0.9.0'),
      box: box,
    );

    final state = await container.read(compatibilityProvider.future);

    expect(state.verdict, CompatibilityVerdict.playerUpdateRequired);
    expect(state.showBanner, isTrue);
    expect(state.serverVersion, '0.9.0');
    expect(state.requiredVersion, '0.9.0');
  });

  test('a failed query yields unknown and no banner', () async {
    final box = await memoryBox();
    final container = harness(
      playerVersion: '0.9.0',
      response:
          graphqlErrorResponse('Cannot query field "serverCompatibility"'),
      box: box,
    );

    final state = await container.read(compatibilityProvider.future);

    expect(state.verdict, CompatibilityVerdict.unknown);
    expect(state.showBanner, isFalse);
  });

  test('dismissing a recommended banner hides it and persists', () async {
    final box = await memoryBox();
    final container = harness(
      playerVersion: '0.8.0',
      response:
          okResponse(version: '0.9.0', min: '0.7.0', recommended: '0.9.0'),
      box: box,
    );

    var state = await container.read(compatibilityProvider.future);
    expect(state.verdict, CompatibilityVerdict.playerUpdateRecommended);
    expect(state.showBanner, isTrue);

    await container.read(compatibilityProvider.notifier).dismiss();

    state = container.read(compatibilityProvider).requireValue;
    expect(state.dismissed, isTrue);
    expect(state.showBanner, isFalse);
    expect(box.isNotEmpty, isTrue);
  });

  test('a dismissal does not carry to a different version pair', () async {
    final box = await memoryBox();

    final first = harness(
      playerVersion: '0.8.0',
      response:
          okResponse(version: '0.9.0', min: '0.7.0', recommended: '0.9.0'),
      box: box,
    );
    await first.read(compatibilityProvider.future);
    await first.read(compatibilityProvider.notifier).dismiss();

    // Same player, but the server moved on. The key changes, so the nudge is
    // live again.
    final second = harness(
      playerVersion: '0.8.0',
      response:
          okResponse(version: '0.10.0', min: '0.7.0', recommended: '0.10.0'),
      box: box,
    );
    final state = await second.read(compatibilityProvider.future);

    expect(state.dismissed, isFalse);
    expect(state.showBanner, isTrue);
  });

  test('a required banner cannot be dismissed', () async {
    final box = await memoryBox();
    final container = harness(
      playerVersion: '0.8.0',
      response: okResponse(version: '0.9.0', min: '0.9.0'),
      box: box,
    );

    await container.read(compatibilityProvider.future);
    await container.read(compatibilityProvider.notifier).dismiss();

    final state = container.read(compatibilityProvider).requireValue;
    expect(state.showBanner, isTrue);
    expect(box.isEmpty, isTrue);
  });

  test('a pre-existing dismissal key does not suppress a required verdict',
      () async {
    final box = await memoryBox();
    const playerVersion = '0.8.0';
    const serverVersion = '0.9.0';

    // Seeded under the exact key build() would look up for this state, so
    // the test proves the required verdict is honored rather than proving an
    // unrelated key simply failed to match.
    const seeded = CompatibilityState(
      verdict: CompatibilityVerdict.playerUpdateRequired,
      playerVersion: playerVersion,
      serverVersion: serverVersion,
    );
    await box.put(seeded.dismissalKey, true);

    final container = harness(
      playerVersion: playerVersion,
      response: okResponse(version: serverVersion, min: serverVersion),
      box: box,
    );

    final state = await container.read(compatibilityProvider.future);

    expect(state.verdict, CompatibilityVerdict.playerUpdateRequired);
    expect(state.showBanner, isTrue);
  });

  test('a pre-existing dismissal key suppresses a matching recommended verdict',
      () async {
    final box = await memoryBox();
    const playerVersion = '0.8.0';
    const serverVersion = '0.9.0';

    // Same pre-seeding mechanism as the required-verdict test above, but here
    // the verdict is dismissible, so the seeded key should take effect. This
    // is what gives the required-verdict test its teeth: it proves a seeded
    // key can suppress a banner at all, so the required-verdict test not
    // suppressing one is meaningful rather than a key that never matched
    // anything.
    const seeded = CompatibilityState(
      verdict: CompatibilityVerdict.playerUpdateRecommended,
      playerVersion: playerVersion,
      serverVersion: serverVersion,
    );
    await box.put(seeded.dismissalKey, true);

    final container = harness(
      playerVersion: playerVersion,
      response: okResponse(
        version: serverVersion,
        min: '0.7.0',
        recommended: serverVersion,
      ),
      box: box,
    );

    final state = await container.read(compatibilityProvider.future);

    expect(state.verdict, CompatibilityVerdict.playerUpdateRecommended);
    expect(state.dismissed, isTrue);
    expect(state.showBanner, isFalse);
  });
}
