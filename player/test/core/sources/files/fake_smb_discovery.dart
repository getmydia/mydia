import 'dart:async';

import 'package:player/core/sources/files/smb_discovery.dart';

/// A scriptable [SmbDiscovery] for widget and provider tests.
class FakeSmbDiscovery implements SmbDiscovery {
  final _controller = StreamController<List<DiscoveredSmbServer>>.broadcast();

  /// How many times [browse] has been listened to.
  int listenCount = 0;

  /// How many [browse] streams have been cancelled.
  int cancelCount = 0;

  void emit(List<DiscoveredSmbServer> servers) => _controller.add(servers);

  /// Matches the real behaviour on a browsing error: an empty list.
  void fail() => _controller.add(const []);

  @override
  Stream<List<DiscoveredSmbServer>> browse() {
    // ignore: close_sinks
    late final StreamController<List<DiscoveredSmbServer>> out;
    StreamSubscription<List<DiscoveredSmbServer>>? sub;
    out = StreamController<List<DiscoveredSmbServer>>(
      onListen: () {
        listenCount++;
        sub = _controller.stream.listen(out.add);
      },
      onCancel: () {
        cancelCount++;
        return sub?.cancel();
      },
    );
    return out.stream;
  }
}
