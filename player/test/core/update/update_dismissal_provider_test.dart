import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/update/update_dismissal_provider.dart';

var _boxCounter = 0;

/// A fresh in-memory Hive box, one per call.
///
/// `bytes:` keeps the box in memory; a disk-backed box hangs the suite for
/// about ten minutes. The name must be unique per call, because
/// `Hive.openBox` hands back the already-open instance for a repeated name,
/// which would leak dismissal keys between tests.
Future<Box<bool>> memoryBox() =>
    Hive.openBox<bool>('update-dismissal-test-${_boxCounter++}',
        bytes: Uint8List(0));

ProviderContainer harness(Box<bool> box) {
  final container = ProviderContainer(
    overrides: [
      updateDismissalBoxProvider.overrideWith((ref) async => box),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(() {
    Hive.init('./.dart_tool/update_dismissal_test');
  });

  test('an empty box dismisses nothing', () async {
    final container = harness(await memoryBox());

    expect(await container.read(updateDismissalProvider.future), isEmpty);
  });

  test('dismissing a version records it', () async {
    final box = await memoryBox();
    final container = harness(box);
    await container.read(updateDismissalProvider.future);

    await container.read(updateDismissalProvider.notifier).dismiss('0.15.0');

    expect(container.read(updateDismissalProvider).value, {'0.15.0'});
    expect(box.get('0.15.0'), isTrue);
  });

  test('a dismissal from a previous session is read back', () async {
    final box = await memoryBox();
    await box.put('0.15.0', true);
    final container = harness(box);

    expect(await container.read(updateDismissalProvider.future), {'0.15.0'});
  });

  test('a later version is not covered by an earlier dismissal', () async {
    // This is the whole reason the key is the version rather than a flag:
    // waving off 0.15.0 must not silence 0.16.0.
    final box = await memoryBox();
    await box.put('0.15.0', true);
    final container = harness(box);

    final dismissed = await container.read(updateDismissalProvider.future);

    expect(dismissed.contains('0.15.0'), isTrue);
    expect(dismissed.contains('0.16.0'), isFalse);
  });

  test('a key explicitly set false is not a dismissal', () async {
    final box = await memoryBox();
    await box.put('0.15.0', false);
    final container = harness(box);

    expect(await container.read(updateDismissalProvider.future), isEmpty);
  });

  test('a box that will not open dismisses nothing rather than everything',
      () async {
    // Fails open on purpose. A broken box must not silence a real update,
    // and the alternative failure mode is invisible: the user simply never
    // hears about an update again.
    final container = ProviderContainer(
      overrides: [
        updateDismissalBoxProvider
            .overrideWith((ref) async => throw StateError('box unavailable')),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(updateDismissalProvider.future), isEmpty);
  });
}
