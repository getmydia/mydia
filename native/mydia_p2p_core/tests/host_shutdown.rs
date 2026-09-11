//! `Host::shutdown` closes the endpoint and ends the event loop, so a host
//! that has been shut down answers every later call the way a dropped one
//! does. This is what lets the server switch remote access off without
//! leaving an iroh endpoint on the network.

use mydia_p2p_core::{blocking, Host, HostConfig};
use std::time::Duration;

/// The endpoint binds and publishes its address asynchronously, so poll
/// rather than sleeping a fixed amount.
fn wait_for_addr(host: &Host) -> String {
    for _ in 0..100 {
        let addr = blocking::get_node_addr(host);
        if !addr.is_empty() && addr != "null" {
            return addr;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("host never published an endpoint address");
}

#[test]
fn shutdown_closes_the_endpoint_and_ends_the_loop() {
    let (host, _node_id) = Host::new(HostConfig::default());
    wait_for_addr(&host);

    blocking::shutdown(&host);

    assert_eq!(blocking::get_node_addr(&host), "");
}

#[test]
fn a_second_shutdown_returns_instead_of_hanging() {
    let (host, _node_id) = Host::new(HostConfig::default());
    wait_for_addr(&host);

    blocking::shutdown(&host);
    blocking::shutdown(&host);

    assert_eq!(blocking::get_node_addr(&host), "");
}
