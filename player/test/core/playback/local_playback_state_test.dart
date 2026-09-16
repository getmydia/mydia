import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_state.dart';

void main() {
  test('acquire and release track nested local players', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(localPlaybackActiveProvider.notifier);

    notifier.acquire();
    notifier.acquire();
    notifier.release();
    expect(container.read(localPlaybackActiveProvider), isTrue);

    notifier.release();
    expect(container.read(localPlaybackActiveProvider), isFalse);
  });

  // `PlayerScreen` captures the notifier in `initState` and calls `acquire`
  // and `release` from microtasks. When the whole `ProviderScope` unmounts in
  // the same frame as the screen, the container is gone by the time the
  // microtask runs, and writing `state` then throws `UnmountedRefException`
  // into whatever zone scheduled it.
  test('release after the container is disposed is a no-op', () {
    final container = ProviderContainer();
    final notifier = container.read(localPlaybackActiveProvider.notifier);
    notifier.acquire();

    container.dispose();

    expect(notifier.release, returnsNormally);
  });

  test('acquire after the container is disposed is a no-op', () {
    final container = ProviderContainer();
    final notifier = container.read(localPlaybackActiveProvider.notifier);

    container.dispose();

    expect(notifier.acquire, returnsNormally);
    expect(() => notifier.setActive(false), returnsNormally);
  });
}
