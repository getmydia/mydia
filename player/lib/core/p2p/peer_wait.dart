import 'dart:async';

/// Waits for [nodeId]'s connected event, or [timeout].
///
/// Subscribes before re-checking [isConnected], so an event that lands
/// between the check and the subscription is not missed.
///
/// Deviates from a `firstWhere(...).timeout(...)` implementation: that shape
/// leaves the `firstWhere` subscription alive after a timeout, because
/// `Future.timeout` does not cancel the stream subscription backing the
/// future it wraps, only the future it returns. This uses an explicit
/// [StreamSubscription] plus a [Timer], both cancelled in every outcome
/// (match, timeout, stream closed, already connected), so no listener or
/// timer outlives the call.
Future<bool> waitForPeer({
  required String nodeId,
  required bool Function() isConnected,
  required Stream<String> connected,
  required Duration timeout,
}) async {
  if (isConnected()) return true;

  final completer = Completer<bool>();
  late final StreamSubscription<String> subscription;
  Timer? timer;

  void finish(bool result) {
    if (completer.isCompleted) return;
    completer.complete(result);
    timer?.cancel();
    unawaited(subscription.cancel());
  }

  subscription = connected.listen(
    (id) {
      if (id == nodeId) finish(true);
    },
    onDone: () => finish(isConnected()),
    onError: (_) => finish(isConnected()),
  );

  // An event can land between the check above and the subscription
  // starting; this re-check covers that race.
  if (isConnected()) {
    finish(true);
  } else {
    timer = Timer(timeout, () => finish(false));
  }

  return completer.future;
}
