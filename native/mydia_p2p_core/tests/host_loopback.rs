//! Two in-process Hosts connect and exchange a Ping.
//!
//! `Ping` is answered inside the event loop (the `matches!(request,
//! MydiaRequest::Ping)` arm in lib.rs), so no application-level response
//! wiring is needed. This test exists to pin the Host lifecycle (spawn, dial,
//! request, response) across the async refactor that follows.

use mydia_p2p_core::{Host, HostConfig, MydiaRequest, MydiaResponse};
use std::time::Duration;

/// The endpoint binds and publishes its address asynchronously, so poll
/// rather than sleeping a fixed amount.
fn wait_for_addr(host: &Host) -> String {
    for _ in 0..100 {
        let addr = host.get_node_addr();
        if !addr.is_empty() && addr != "null" {
            return addr;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("host never published an endpoint address");
}

#[test]
fn two_hosts_exchange_ping() {
    let rt = tokio::runtime::Runtime::new().expect("test runtime");

    let (server, server_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server_addr = wait_for_addr(&server);
    client.dial(server_addr).expect("dial should succeed");

    let response = rt
        .block_on(async {
            tokio::time::timeout(
                Duration::from_secs(30),
                client.send_request(server_id.clone(), MydiaRequest::Ping),
            )
            .await
        })
        .expect("ping timed out")
        .expect("ping returned an error");

    assert!(
        matches!(response, MydiaResponse::Pong),
        "expected Pong, got {response:?}"
    );
}
