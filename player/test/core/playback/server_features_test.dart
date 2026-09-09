import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/playback/server_features.dart';

class _ConnectionHarness extends ConnectionNotifier {
  @override
  ConnectionState build() => ConnectionState.direct();

  void connect(String serverNodeAddr) {
    state = ConnectionState.p2p(serverNodeAddr: serverNodeAddr);
  }

  void signOut() {
    state = ConnectionState.direct();
  }
}

void main() {
  ProviderContainer container() => ProviderContainer(overrides: [
        connectionProvider.overrideWith(_ConnectionHarness.new),
      ]);

  test('keeps legacy capability learning for the same connection', () {
    final scope = container();
    addTearDown(scope.dispose);
    final connection =
        scope.read(connectionProvider.notifier) as _ConnectionHarness;

    connection.connect('server-one');
    final learned = scope.read(serverFeaturesProvider);
    learned.heightCap = false;

    expect(scope.read(serverFeaturesProvider), same(learned));
    expect(scope.read(serverFeaturesProvider).heightCap, isFalse);
  });

  test('renegotiates capabilities after sign-out and reconnect', () {
    final scope = container();
    addTearDown(scope.dispose);
    final connection =
        scope.read(connectionProvider.notifier) as _ConnectionHarness;

    connection.connect('old-server');
    final oldFeatures = scope.read(serverFeaturesProvider);
    oldFeatures.heightCap = false;

    connection.signOut();
    connection.connect('new-server');
    final newFeatures = scope.read(serverFeaturesProvider);

    expect(newFeatures, isNot(same(oldFeatures)));
    expect(newFeatures.heightCap, isTrue);
  });
}
