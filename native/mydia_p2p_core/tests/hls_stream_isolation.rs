// native/mydia_p2p_core/tests/hls_stream_isolation.rs
use mydia_p2p_core::{
    Event, HlsRequest, HlsResponseHeader, Host, HostConfig, MydiaRequest, MydiaResponse,
};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn test_config() -> HostConfig {
    HostConfig {
        relay_urls: Vec::new(),
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    }
}

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
async fn hls_stream_does_not_block_concurrent_requests() {
    let (server, server_id) = Host::new(test_config());
    let (client, _client_id) = Host::new(test_config());

    let server = Arc::new(server);
    let client = Arc::new(client);

    let server_addr = wait_for_addr(&server).await;
    client.dial(server_addr).await.expect("dial failed");

    // Server event listener task: handles RequestReceived and captures HlsStreamRequest
    let server_for_events = server.clone();
    let (hls_stream_id_tx, hls_stream_id_rx) = tokio::sync::oneshot::channel();
    let mut hls_stream_id_tx = Some(hls_stream_id_tx);

    let server_event_task = tokio::spawn(async move {
        let mut rx = server_for_events.event_rx.lock().await;
        while let Some(event) = rx.recv().await {
            match event {
                Event::HlsStreamRequest { stream_id, .. } => {
                    if let Some(tx) = hls_stream_id_tx.take() {
                        let _ = tx.send(stream_id);
                    }
                }
                Event::RequestReceived { request_id, .. } => {
                    let s = server_for_events.clone();
                    tokio::spawn(async move {
                        s.send_response(request_id, MydiaResponse::Custom(vec![99]))
                            .await
                            .expect("send_response failed");
                    });
                }
                _ => {}
            }
        }
    });

    // Client requests HLS stream
    let hls_req = HlsRequest {
        session_id: "test_session".to_string(),
        path: "stream.m3u8".to_string(),
        range_start: None,
        range_end: None,
        auth_token: None,
    };

    let client_for_hls = client.clone();
    let sid = server_id.clone();
    let client_hls_handle = tokio::spawn(async move {
        client_for_hls.send_hls_request(sid, hls_req).await
    });

    let stream_id = hls_stream_id_rx.await.expect("did not get stream_id");

    // Server sends HLS header
    let header = HlsResponseHeader {
        status: 200,
        content_type: "video/mp2t".to_string(),
        content_length: 10 * 1024 * 1024,
        content_range: None,
        cache_control: None,
    };
    server
        .send_hls_header(stream_id.clone(), header)
        .await
        .expect("send_hls_header failed");

    let mut stream_resp = client_hls_handle
        .await
        .unwrap()
        .expect("send_hls_request failed");

    // Start pushing a huge chunk (150MB) from the server that exceeds the QUIC window
    // and causes send.write_all() to block when client does not read chunk_rx yet
    let server_for_chunk = server.clone();
    let stream_id_clone = stream_id.clone();
    let chunk_handle = tokio::spawn(async move {
        let big_chunk = vec![7u8; 150 * 1024 * 1024];
        server_for_chunk.send_hls_chunk(stream_id_clone, big_chunk).await
    });

    // Wait a brief moment for write_all to enter backpressure
    tokio::time::sleep(Duration::from_millis(200)).await;

    // While HLS chunk write is backpressured / active, client sends a concurrent Custom request
    let req_start = Instant::now();
    let resp = tokio::time::timeout(
        Duration::from_secs(3),
        client.send_request(server_id.clone(), MydiaRequest::Custom(vec![1, 2, 3])),
    )
    .await
    .expect("send_request timed out while HLS chunk was in flight")
    .expect("send_request failed");

    let req_elapsed = req_start.elapsed();
    assert_eq!(resp, MydiaResponse::Custom(vec![99]));
    assert!(
        req_elapsed < Duration::from_millis(500),
        "concurrent request took {req_elapsed:?}, expected < 500ms"
    );

    // Now client drains chunks so chunk_handle can complete
    let drain_handle = tokio::spawn(async move {
        while let Some(_) = stream_resp.chunk_rx.recv().await {}
    });

    chunk_handle.await.unwrap().expect("chunk send failed");
    server
        .finish_hls_stream(stream_id)
        .await
        .expect("finish failed");
    let _ = drain_handle.await;
    server_event_task.abort();
}
