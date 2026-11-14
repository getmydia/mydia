//! `Host::shutdown` closes the endpoint and ends the event loop, so a host
//! that has been shut down answers every later call the way a dropped one
//! does. This is what lets the server switch remote access off without
//! leaving an iroh endpoint on the network.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "integration test crate: helpers outside #[test] fns are test code too"
)]

use mydia_p2p_core::{blocking, HlsResponseHeader, Host, HostConfig};
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

/// A responder outliving its host must not keep the host's command channel
/// open: the player's event dispatcher holds one for as long as the event
/// channel is open, and that channel closes only once the loop has ended.
/// With a strong sender the dropped host's loop would answer this call
/// itself; with the weak one the call fails before it is ever sent.
#[tokio::test(flavor = "multi_thread")]
async fn a_responder_does_not_keep_a_dropped_host_alive() {
    let (host, _node_id) = Host::new(HostConfig::default());
    let responder = host.hls_responder();
    drop(host);

    let result = responder
        .send_header(
            "missing".to_string(),
            HlsResponseHeader {
                status: 200,
                content_type: "video/mp4".to_string(),
                content_length: 0,
                content_range: None,
                cache_control: None,
            },
        )
        .await;

    assert_eq!(result, Err("send_failed".to_string()));
}

/// A host still waiting for its relay answers Shutdown at once instead of
/// after the wait, which lasts up to 30 s when the relay cannot be reached.
/// Online the wait is short, so this only catches a regression offline.
#[test]
fn shutdown_during_the_relay_wait_returns_promptly() {
    let (host, _node_id) = Host::new(HostConfig::default());
    let started = std::time::Instant::now();

    blocking::shutdown(&host);

    assert!(
        started.elapsed() < Duration::from_secs(10),
        "shutdown took {:?}",
        started.elapsed()
    );
    assert_eq!(blocking::get_node_addr(&host), "");
}
