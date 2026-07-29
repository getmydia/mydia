import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// `ProviderListenable` is not re-exported by the main `flutter_riverpod.dart`
// barrel in Riverpod 3.x; it lives in the `misc.dart` sub-library alongside
// other advanced/library-author types.
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// Waits for [provider] to emit a value satisfying [predicate].
///
/// Needed because `cacheAndNetwork` emits the cached value first and the
/// network value second: awaiting `.future` would only ever see the first.
///
/// For a `StreamNotifierProvider`, a failure arrives as an ordinary
/// [AsyncValue] (an [AsyncError]) delivered to this same listener, not as a
/// stream error — so on any GraphQL or parse failure, [predicate] is simply
/// never satisfied and this would otherwise time out with no indication of
/// why. The most recently observed value is tracked and folded into the
/// timeout failure message so the real error text reaches the test report,
/// instead of a bare "Future not completed".
Future<T> waitForValue<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider,
  bool Function(T value) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<T>();
  AsyncValue<T>? lastValue;

  final subscription = container.listen<AsyncValue<T>>(
    provider,
    (previous, next) {
      lastValue = next;
      final value = next.value;
      if (value != null && predicate(value) && !completer.isCompleted) {
        completer.complete(value);
      }
    },
    fireImmediately: true,
  );

  try {
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'waitForValue: timed out after $timeout waiting for a value '
        'matching the predicate. Last value seen: $lastValue',
      ),
    );
  } finally {
    subscription.close();
  }
}
