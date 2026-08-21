import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'p2p_streaming_test.dart' as p2p_streaming;
import 'pairing_flow_test.dart' as pairing_flow;
import 'remote_control_test.dart' as remote_control;
import 'secure_storage_test.dart' as secure_storage;
import 'simple_test.dart' as simple;

/// Runs every integration test file in a single app build.
///
/// Pointing `flutter test` at the directory instead would build the app once
/// per file. Each file's `main` only registers tests and setUpAll callbacks,
/// so wrapping them in groups is safe.
///
/// Order matters, though only in part. `simple` runs first: it boots `MyApp`,
/// which initializes P2P, so a real host starts and tears down before
/// `pairing_flow` claims the device. `pairing_flow` runs next because it
/// consumes the single-use E2E_CLAIM_CODE passed via --dart-define.
/// `p2p_streaming` mints its own claim codes through the API, so it does not
/// depend on `pairing_flow` having run first. `remote_control` sits with it
/// for the same reason: it mints its own codes for both of the players it
/// pairs, so it never touches the single-use one either.
///
/// Registering a file here is what makes CI run it — `ci-player-e2e.yml` sets
/// `E2E_TEST_TARGET: integration_test/all_tests.dart`, so a file left out is
/// inert no matter how thorough it is.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('simple', simple.main);
  group('pairing_flow', pairing_flow.main);
  group('p2p_streaming', p2p_streaming.main);
  group('remote_control', remote_control.main);
  group('secure_storage', secure_storage.main);
}
