/// The remote-control protocol revision this build speaks — both as a
/// controller (`MydiaCastBackend` sends this on every `Hello`) and as a
/// target (`RemoteControlReceiver` reports this on every `Welcome`).
///
/// Mirrors `PROTOCOL_VERSION` in `native/mydia_p2p_core/src/remote_control.rs`:
/// bump when a command's meaning changes, never when one is merely added —
/// `FlutterTargetCapabilities` is how a target declines a command it does
/// not implement.
///
/// Shared as one constant, rather than each side hardcoding its own literal,
/// specifically so a target reports what it actually speaks instead of
/// echoing whatever the controller sent on `Hello` — echoing would make a
/// version mismatch permanently invisible, since the controller's own
/// request would always come back unchanged regardless of what the target
/// understands.
const remoteControlProtocolVersion = 1;
