import '../../native/lib.dart';

/// The claim-code operations [RelayApiClient] needs, bundled behind one handle.
///
/// Bundled rather than exposed as two functions so the Argon2id derivation runs
/// once per resolve. At 64 MiB it costs a few hundred milliseconds on a phone
/// and more in a browser, and both the lookup and the open need the same seed.
///
/// Abstract so tests can exercise the HTTP behaviour without loading the Rust
/// native library. CI's `Test / Player` job runs `flutter test` with no cargo
/// build, so anything reaching `RustLib.init` fails there. The derivation and
/// sealing themselves are covered by Rust tests in `mydia_p2p_core` and
/// `mydia_player_p2p`, which is where that logic actually lives.
abstract class PairingKeyHandle {
  /// The relay URL path segment: 64 lowercase hex characters.
  Future<String> lookupKey();

  /// Opens a sealed blob fetched from the relay.
  ///
  /// Throws if the blob does not verify. A wrong code cannot produce a lookup
  /// hit short of a 256-bit collision, so a blob that fetches but will not open
  /// was altered in storage or in transit.
  Future<({String nodeAddr, String instanceId})> open(String sealed);
}

/// Builds a handle for a claim code as the user typed it. Case, dashes, and
/// whitespace are normalized inside the Rust core.
typedef PairingKeyFactory = PairingKeyHandle Function(String code);

/// The real handle, backed by the shared Rust implementation.
class NativePairingKeyHandle implements PairingKeyHandle {
  final PairingKeys _keys;

  NativePairingKeyHandle(String code) : _keys = PairingKeys.derive(code: code);

  @override
  Future<String> lookupKey() => _keys.lookupKey();

  @override
  Future<({String nodeAddr, String instanceId})> open(String sealed) async {
    final payload = await _keys.open(sealed: sealed);
    return (nodeAddr: payload.nodeAddr, instanceId: payload.instanceId);
  }
}

PairingKeyHandle defaultPairingKeyFactory(String code) =>
    NativePairingKeyHandle(code);
