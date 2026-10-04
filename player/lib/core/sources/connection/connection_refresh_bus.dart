/// The app-wide moments every source connection should look again: the app
/// came back to the foreground, or the network changed.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ConnectionRefreshReason { resume, network }

class ConnectionRefreshBus {
  final _events = StreamController<ConnectionRefreshReason>.broadcast();

  Stream<ConnectionRefreshReason> get events => _events.stream;

  void ping(ConnectionRefreshReason reason) {
    if (!_events.isClosed) _events.add(reason);
  }

  Future<void> close() => _events.close();
}

final connectionRefreshBusProvider = Provider<ConnectionRefreshBus>((ref) {
  final bus = ConnectionRefreshBus();
  ref.onDispose(bus.close);
  return bus;
});

/// Platform connectivity changes. A seam so tests can inject a stream.
final connectivityChangesProvider = Provider<Stream<Object?>>(
  (ref) => Connectivity().onConnectivityChanged,
);

/// Forwards network changes to the bus while read. `app.dart` reads it once
/// at start; tests never do, so no platform channel is touched under test.
///
/// The Linux plugin opens its NetworkManager D-Bus session asynchronously and
/// throws into the current zone, not onto the stream, when there is no bus
/// (containers, some sandboxes). Starting the listener inside a guarded zone
/// keeps that from escaping; network-change refresh then stays off while
/// resume and the periodic timer still refresh.
final networkChangeRefreshProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  final bus = ref.watch(connectionRefreshBusProvider);
  StreamSubscription<Object?>? subscription;
  void unavailable(Object e, [StackTrace? _]) =>
      debugPrint('[Sources] Connectivity events unavailable: $e');
  runZonedGuarded(() {
    try {
      subscription = ref.read(connectivityChangesProvider).listen(
            (_) => bus.ping(ConnectionRefreshReason.network),
            onError: unavailable,
          );
    } catch (e) {
      unavailable(e);
    }
  }, unavailable);
  ref.onDispose(() => subscription?.cancel());
});
