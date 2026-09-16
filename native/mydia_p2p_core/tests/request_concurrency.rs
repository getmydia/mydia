// native/mydia_p2p_core/tests/request_concurrency.rs
use mydia_p2p_core::{Host, HostConfig, MydiaRequest, MydiaResponse};
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
async fn fast_request_does_not_queue_behind_slow_request() {
    let (server, server_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server = Arc::new(server);
    let client = Arc::new(client);

    let server_addr = wait_for_addr(&server).await;
    client.dial(server_addr).await.expect("dial failed");

    // Responder sleeps 200ms before answering the Custom request.
    let server_clone = server.clone();
    let responder_handle = tokio::spawn(async move {
        let mut rx = server_clone.event_rx.lock().await;
        while let Some(event) = rx.recv().await {
            if let mydia_p2p_core::Event::RequestReceived { request_id, .. } = event {
                tokio::time::sleep(Duration::from_millis(200)).await;
                server_clone
                    .send_response(request_id, MydiaResponse::Custom(vec![42]))
                    .await
                    .expect("send_response failed");
                break;
            }
        }
    });

    // Client dispatches a slow request in the background
    let slow_client = client.clone();
    let slow_sid = server_id.clone();
    let slow_handle = tokio::spawn(async move {
        slow_client
            .send_request(slow_sid, MydiaRequest::Custom(vec![1]))
            .await
    });

    // Ensure the slow request has arrived and is being processed by the client event loop
    tokio::time::sleep(Duration::from_millis(30)).await;

    // Fast request (Ping) should be dispatched concurrently without waiting for the slow request
    let fast_start = Instant::now();
    let fast_resp = client
        .send_request(server_id.clone(), MydiaRequest::Ping)
        .await
        .expect("ping failed");
    let fast_elapsed = fast_start.elapsed();

    assert!(matches!(fast_resp, MydiaResponse::Pong));
    assert!(
        fast_elapsed < Duration::from_millis(100),
        "fast request took {fast_elapsed:?}, expected < 100ms because it should not queue behind 200ms request"
    );

    let slow_resp = slow_handle.await.unwrap().expect("slow request failed");
    assert_eq!(slow_resp, MydiaResponse::Custom(vec![42]));
    responder_handle.await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn twenty_concurrent_requests_execute_quickly() {
    let (server, server_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server_addr = wait_for_addr(&server).await;
    client.dial(server_addr).await.expect("dial failed");

    let start = Instant::now();
    let mut futures = Vec::new();
    for _ in 0..20 {
        let s_id = server_id.clone();
        let client_clone = &client;
        futures.push(async move { client_clone.send_request(s_id, MydiaRequest::Ping).await });
    }

    let results = futures::future::join_all(futures).await;
    let elapsed = start.elapsed();

    for res in results {
        let resp = res.expect("request failed");
        assert!(matches!(resp, MydiaResponse::Pong));
    }

    assert!(
        elapsed < Duration::from_millis(500),
        "20 concurrent requests took {elapsed:?}, expected < 500ms"
    );
}
