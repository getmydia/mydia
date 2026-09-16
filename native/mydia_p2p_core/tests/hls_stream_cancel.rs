//! A client that abandons an HLS stream must stop the server sending it.
//!
//! A player closes its connection to the local proxy on every seek. Unless
//! that close reaches the server, the old transfer keeps running to the end
//! of the file and shares the connection with the one that is playing.

use mydia_p2p_core::{
    Event, HlsRequest, HlsResponseHeader, HlsStreamResponse, Host, HostConfig, HLS_PEER_STOPPED,
};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const GIB: u64 = 1024 * 1024 * 1024;

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

/// A large file that takes no disk space, so the server cannot finish
/// sending it before the test cancels.
fn sparse_file(name: &str, len: u64) -> PathBuf {
    let path = std::env::temp_dir().join(format!("{name}-{}.bin", std::process::id()));
    std::fs::File::create(&path)
        .and_then(|file| file.set_len(len))
        .expect("create sparse file");
    path
}

/// Connects a client to a server, opens a stream and answers its header.
/// Returns the server, the client (kept alive by the caller), the server's
/// stream id, the client's response, and the server's event task.
async fn open_stream() -> (
    Arc<Host>,
    Arc<Host>,
    String,
    HlsStreamResponse,
    tokio::task::JoinHandle<()>,
) {
    let (server, server_id) = Host::new(test_config());
    let (client, _client_id) = Host::new(test_config());
    let server = Arc::new(server);
    let client = Arc::new(client);

    let server_addr = wait_for_addr(&server).await;
    client.dial(server_addr).await.expect("dial failed");

    let (id_tx, id_rx) = tokio::sync::oneshot::channel();
    let events_host = server.clone();
    let events = tokio::spawn(async move {
        let mut id_tx = Some(id_tx);
        let mut rx = events_host.event_rx.lock().await;
        while let Some(event) = rx.recv().await {
            if let Event::HlsStreamRequest { stream_id, .. } = event {
                if let Some(tx) = id_tx.take() {
                    let _ = tx.send(stream_id);
                }
            }
        }
    });

    let request = HlsRequest {
        session_id: "direct:file-1".to_string(),
        path: "stream".to_string(),
        range_start: Some(0),
        range_end: None,
        auth_token: None,
    };
    let requester = client.clone();
    let response =
        tokio::spawn(async move { requester.send_hls_request(server_id, request).await });

    let stream_id = id_rx.await.expect("server never saw the stream");
    server
        .send_hls_header(
            stream_id.clone(),
            HlsResponseHeader {
                status: 200,
                content_type: "video/x-matroska".to_string(),
                content_length: 8 * GIB,
                content_range: None,
                cache_control: None,
            },
        )
        .await
        .expect("send_hls_header failed");

    let response = response.await.unwrap().expect("send_hls_request failed");
    (server, client, stream_id, response, events)
}

#[tokio::test(flavor = "multi_thread")]
async fn cancel_stops_the_server_streaming_a_file() {
    let (server, _client, stream_id, response, events) = open_stream().await;
    let HlsStreamResponse {
        mut chunk_rx,
        cancel,
        ..
    } = response;
    let path = sparse_file("hls_stream_cancel", 8 * GIB);

    let streaming = {
        let server = server.clone();
        let path = path.to_string_lossy().into_owned();
        tokio::spawn(async move { server.stream_file_range(stream_id, path, 0, 8 * GIB).await })
    };

    let first = tokio::time::timeout(Duration::from_secs(5), chunk_rx.recv())
        .await
        .expect("no chunk arrived")
        .expect("stream ended before any data");
    assert!(!first.is_empty());

    cancel.cancel();

    let result = tokio::time::timeout(Duration::from_secs(10), streaming)
        .await
        .expect("server still streaming 10s after the client cancelled")
        .expect("streaming task panicked");
    let _ = std::fs::remove_file(&path);

    let err = result.expect_err("server sent all 8 GiB to a client that cancelled");
    assert!(err.starts_with(HLS_PEER_STOPPED), "unexpected error: {err}");
    events.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn cancel_ends_a_stream_the_server_has_stalled() {
    let (_server, _client, _stream_id, response, events) = open_stream().await;
    let HlsStreamResponse {
        mut chunk_rx,
        cancel,
        ..
    } = response;

    // The server answered the header and then went quiet.
    let quiet = tokio::time::timeout(Duration::from_millis(300), chunk_rx.recv()).await;
    assert!(quiet.is_err(), "a stalled stream produced data");

    cancel.cancel();

    let next = tokio::time::timeout(Duration::from_secs(2), chunk_rx.recv())
        .await
        .expect("cancel left the reader waiting on the stalled server");
    assert!(next.is_none());
    events.abort();
}

/// Dropping the cancel handle unused is not a cancel: the buffered request
/// path discards it and reads the whole response.
#[tokio::test(flavor = "multi_thread")]
async fn dropping_the_cancel_handle_does_not_cancel() {
    const LEN: u64 = 4 * 1024 * 1024;
    let (server, _client, stream_id, response, events) = open_stream().await;
    let HlsStreamResponse {
        mut chunk_rx,
        cancel,
        ..
    } = response;
    drop(cancel);

    let path = sparse_file("hls_stream_cancel_drop", LEN);
    let streaming = {
        let server = server.clone();
        let path = path.to_string_lossy().into_owned();
        tokio::spawn(async move { server.stream_file_range(stream_id, path, 0, LEN).await })
    };

    let mut received = 0u64;
    while let Some(chunk) = tokio::time::timeout(Duration::from_secs(10), chunk_rx.recv())
        .await
        .expect("stream stalled")
    {
        received += chunk.len() as u64;
    }
    let result = tokio::time::timeout(Duration::from_secs(10), streaming)
        .await
        .expect("server still streaming")
        .expect("streaming task panicked");
    let _ = std::fs::remove_file(&path);

    result.expect("server failed to finish the file");
    assert_eq!(received, LEN, "the stream ended early");
    events.abort();
}
