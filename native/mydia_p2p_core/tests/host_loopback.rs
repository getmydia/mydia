//! Two in-process Hosts connect and exchange a Ping.
//!
//! `Ping` is answered inside the event loop (the `matches!(request,
//! MydiaRequest::Ping)` arm in lib.rs), so no application-level response
//! wiring is needed. This test exists to pin the Host lifecycle (spawn, dial,
//! request, response) across the async refactor that follows.

use mydia_p2p_core::{blocking, Host, HostConfig, MydiaRequest, MydiaResponse};
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
fn two_hosts_exchange_ping() {
    let rt = tokio::runtime::Runtime::new().expect("test runtime");

    let (server, server_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server_addr = wait_for_addr(&server);
    blocking::dial(&client, server_addr).expect("dial should succeed");

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

/// The same exchange, driven entirely from async context. After the refactor
/// this is the shape every caller other than the Rustler NIF uses.
#[test]
fn two_hosts_exchange_ping_from_async() {
    let rt = tokio::runtime::Runtime::new().expect("test runtime");

    rt.block_on(async {
        let (server, server_id) = Host::new(HostConfig::default());
        let (client, _client_id) = Host::new(HostConfig::default());

        let mut server_addr = String::new();
        for _ in 0..100 {
            server_addr = server.get_node_addr().await;
            if !server_addr.is_empty() && server_addr != "null" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(!server_addr.is_empty(), "host never published an address");

        client.dial(server_addr).await.expect("dial should succeed");

        let response = tokio::time::timeout(
            Duration::from_secs(30),
            client.send_request(server_id.clone(), MydiaRequest::Ping),
        )
        .await
        .expect("ping timed out")
        .expect("ping returned an error");

        assert!(
            matches!(response, MydiaResponse::Pong),
            "expected Pong, got {response:?}"
        );
    });
}
