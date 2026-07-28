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
Future<T> waitForValue<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider,
  bool Function(T value) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<T>();

  final subscription = container.listen<AsyncValue<T>>(
    provider,
    (previous, next) {
      final value = next.value;
      if (value != null && predicate(value) && !completer.isCompleted) {
        completer.complete(value);
      }
    },
    fireImmediately: true,
  );

  try {
    return await completer.future.timeout(timeout);
  } finally {
    subscription.close();
  }
}
