// native/mydia_p2p_core/tests/dial_concurrency.rs
use mydia_p2p_core::{Host, HostConfig};
use std::sync::Arc;
use std::time::{Duration, Instant};

async fn wait_for_addr(host: &Host) -> String {
    for _ in 0..100 {
        let addr = host.get_node_addr().await;
        if !addr.is_empty() && addr != "null" {
            return addr;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("host never published an endpoint address");
}

#[tokio::test(flavor = "multi_thread")]
async fn slow_or_unreachable_dial_does_not_block_local_queries() {
    let (host, _node_id) = Host::new(HostConfig::default());
    let (other_host, other_node_id) = Host::new(HostConfig::default());
    other_host.shutdown().await;
    let host = Arc::new(host);

    let _addr = wait_for_addr(&host).await;

    // Construct an endpoint address pointing to documentation IP 192.0.2.1 with a different node ID
    let unreachable_addr = format!(
        r#"{{"id":"{}","addrs":[{{"Ip":"192.0.2.1:12345"}}]}}"#,
        other_node_id
    );

    // Spawn the dial in the background (it will take a long time to fail/timeout)
    let dial_host = host.clone();
    let dial_handle = tokio::spawn(async move { dial_host.dial(unreachable_addr).await });

    // Give the dial command a moment to reach the event loop and start connecting
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Concurrent local queries should complete immediately without blocking on the dial
    let start = Instant::now();
    let node_addr = host.get_node_addr().await;
    let stats = host.get_network_stats().await;
    let elapsed = start.elapsed();

    assert!(!node_addr.is_empty(), "get_node_addr returned empty");
    assert_eq!(stats.connected_peers, 0);
    assert!(
        elapsed < Duration::from_millis(100),
        "local queries took {elapsed:?}, expected < 100ms because dial should not block the event loop"
    );

    // Cancel the background dial and shut down host so the test exits cleanly
    dial_handle.abort();
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn invalid_endpoint_addr_json_returns_error_immediately() {
    let (host, _node_id) = Host::new(HostConfig::default());
    let _addr = wait_for_addr(&host).await;

    let start = Instant::now();
    let result = host.dial("{not valid json".to_string()).await;
    let elapsed = start.elapsed();

    assert!(result.is_err());
    assert!(
        elapsed < Duration::from_millis(50),
        "invalid json rejected immediately without blocking: {elapsed:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_dials_to_valid_peers_both_succeed() {
    let (server1, server1_id) = Host::new(HostConfig::default());
    let (server2, server2_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server1_addr = wait_for_addr(&server1).await;
    let server2_addr = wait_for_addr(&server2).await;

    let c = Arc::new(client);
    let c1 = c.clone();
    let c2 = c.clone();

    let dial1 = tokio::spawn(async move { c1.dial(server1_addr).await });
    let dial2 = tokio::spawn(async move { c2.dial(server2_addr).await });

    let (res1, res2) = tokio::join!(dial1, dial2);
    res1.unwrap().expect("dial 1 should succeed");
    res2.unwrap().expect("dial 2 should succeed");

    let stats = c.get_network_stats().await;
    assert_eq!(stats.connected_peers, 2);

    let resp1 = c
        .send_request(server1_id, mydia_p2p_core::MydiaRequest::Ping)
        .await
        .unwrap();
    let resp2 = c
        .send_request(server2_id, mydia_p2p_core::MydiaRequest::Ping)
        .await
        .unwrap();
    assert!(matches!(resp1, mydia_p2p_core::MydiaResponse::Pong));
    assert!(matches!(resp2, mydia_p2p_core::MydiaResponse::Pong));
}
