import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/connection/connection_refresh_bus.dart';

void main() {
  test('async error during listen does not surface as uncaught', () async {
    final controller = StreamController<Object?>.broadcast(
      onListen: () {
        Timer.run(() => throw StateError('no bus'));
      },
    );
    final container = ProviderContainer(overrides: [
      connectivityChangesProvider.overrideWithValue(controller.stream),
    ]);
    addTearDown(() async {
      container.dispose();
      await controller.close();
    });

    container.read(networkChangeRefreshProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // An uncaught error would fail the test here.
  });

  test('network events ping the bus', () async {
    final controller = StreamController<Object?>.broadcast();
    final container = ProviderContainer(overrides: [
      connectivityChangesProvider.overrideWithValue(controller.stream),
    ]);
    addTearDown(() async {
      container.dispose();
      await controller.close();
    });
    final events = <ConnectionRefreshReason>[];
    container.read(connectionRefreshBusProvider).events.listen(events.add);
    container.read(networkChangeRefreshProvider);
    controller.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(events, [ConnectionRefreshReason.network]);
  });
}
