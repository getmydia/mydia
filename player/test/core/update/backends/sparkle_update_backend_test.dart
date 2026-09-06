import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/sparkle_update_backend.dart';
import 'package:player/core/update/update_backend.dart';

void main() {
  test('refresh does not trigger a Sparkle check', () async {
    // Sparkle already checks on launch by itself. Calling the injected
    // checker from refresh() too would open its native dialog every time
    // Settings opens, unprompted.
    var calls = 0;
    final backend = SparkleUpdateBackend(checkForUpdates: () async => calls++);

    await backend.refresh();

    expect(calls, 0);
  });

  test('requestUpdate invokes the injected check exactly once and defers',
      () async {
    var calls = 0;
    final backend = SparkleUpdateBackend(checkForUpdates: () async => calls++);

    final outcome = await backend.requestUpdate();

    expect(calls, 1);
    expect(outcome, isA<UpdateDeferred>());
  });

  test('manualCheck delegates to Sparkle', () {
    final backend = SparkleUpdateBackend(checkForUpdates: () async {});

    expect(backend.manualCheck, ManualCheckBehaviour.delegatesToSparkle);
  });

  test('canUpdateInPlace is true', () {
    final backend = SparkleUpdateBackend(checkForUpdates: () async {});

    expect(backend.canUpdateInPlace, isTrue);
  });
}
