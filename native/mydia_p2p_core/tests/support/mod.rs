//! Shared by the integration tests.

use mydia_p2p_core::{Host, HostConfig};

/// A host for a test. With `test-introspection` (how CI and the pre-commit
/// hook run these tests) it is `Host::new_offline`: no relays and no relay
/// wait, so it is ready at once and never reaches for iroh's public relays,
/// which a sandboxed build cannot reach. Peers connect over the direct
/// addresses in its `EndpointAddr`. Without the feature it is a real
/// `Host::new`, which needs the network and waits up to 30s for a relay.
pub fn host(config: HostConfig) -> (Host, String) {
    #[cfg(feature = "test-introspection")]
    {
        Host::new_offline(config)
    }
    #[cfg(not(feature = "test-introspection"))]
    {
        Host::new(config)
    }
}
