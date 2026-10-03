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

/// Forwards network changes to the bus while read. `app.dart` reads it once
/// at start; tests never do, so no platform channel is touched under test.
final networkChangeRefreshProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  final bus = ref.watch(connectionRefreshBusProvider);
  final subscription = Connectivity().onConnectivityChanged.listen(
        (_) => bus.ping(ConnectionRefreshReason.network),
        onError: (Object e) =>
            debugPrint('[Sources] Connectivity events unavailable: $e'),
      );
  ref.onDispose(subscription.cancel);
});
