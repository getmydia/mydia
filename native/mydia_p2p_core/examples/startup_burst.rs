//! Reproduces the player's startup burst: dial a peer, then fire a batch of
//! GraphQL requests the moment the (relay) connection comes up, while iroh is
//! still migrating to a direct path. Prints each request's latency.
//!
//! ```text
//! PEER_JSON='{"id":"...","addrs":[...]}' \
//! RUST_LOG=info,noq_proto=debug \
//! cargo run --example startup_burst -- [requests] [payload_bytes]
//! ```
//!
//! With no auth token the server answers each request with an error, which
//! is all this needs: whether an answer arrives, and when.

#![expect(
    clippy::print_stdout,
    clippy::expect_used,
    clippy::panic,
    reason = "command-line example: prints its results and aborts on failure"
)]

use mydia_p2p_core::{Event, GraphQLRequest, Host, HostConfig, MydiaRequest};
use std::{env, sync::Arc, time::Instant};

#[tokio::main]
async fn main() {
    // With MYDIA_P2P_TRACE_FILE set, leave the subscriber to the crate's own
    // `init_tracing`, the path the server NIF takes, so the trace file can be
    // checked end to end.
    if env::var_os("MYDIA_P2P_TRACE_FILE").is_none() {
        tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .init();
    }

    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--listen") {
        listen().await;
        return;
    }
    let requests: usize = args.first().and_then(|s| s.parse().ok()).unwrap_or(10);
    let payload: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(2000);
    let peer_json = env::var("PEER_JSON").expect("PEER_JSON must be set");
    let peer_id = serde_json::from_str::<serde_json::Value>(&peer_json).expect("PEER_JSON is JSON")
        ["id"]
        .as_str()
        .expect("PEER_JSON has an id")
        .to_string();

    let (host, _node_id) = Host::new(HostConfig {
        relay_urls: vec![
            "https://cae1-1.relay.mydia.dev".to_string(),
            "https://cae1-2.relay.mydia.dev".to_string(),
        ],
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    });
    let host = Arc::new(host);

    let t0 = Instant::now();
    host.dial(peer_json).await.expect("dial failed");
    wait_for_connected(&host).await;
    println!("{:>7.3}s connected", t0.elapsed().as_secs_f64());

    let mut tasks = Vec::new();
    for i in 0..requests {
        let host = Arc::clone(&host);
        let peer_id = peer_id.clone();
        let query = format!(
            "query StartupBurst{i} {{ __typename }} #{}",
            "x".repeat(payload)
        );
        tasks.push(tokio::spawn(async move {
            let sent = Instant::now();
            let result = host
                .send_request(
                    peer_id,
                    MydiaRequest::GraphQL(GraphQLRequest {
                        query,
                        variables: None,
                        operation_name: None,
                        auth_token: None,
                        device_profile: None,
                    }),
                )
                .await;
            (i, sent.elapsed(), result.map(|_| ()))
        }));
    }
    for task in tasks {
        let (i, took, result) = task.await.expect("task panicked");
        println!("request {i:>2}: {:>7.3}s {result:?}", took.as_secs_f64());
    }
    println!("{:>7.3}s done", t0.elapsed().as_secs_f64());
}

/// Answers every request with a small `Custom` response, forever. Prints the
/// address JSON to hand the dialer as `PEER_JSON`.
async fn listen() {
    let (host, _node_id) = Host::new(HostConfig {
        relay_urls: vec![
            "https://cae1-1.relay.mydia.dev".to_string(),
            "https://cae1-2.relay.mydia.dev".to_string(),
        ],
        bind_port: Some(0),
        // KEYPAIR_PATH lets the listener stand in for a real server's identity.
        keypair_path: env::var("KEYPAIR_PATH").ok(),
        keypair_bytes: None,
    });
    let host = Arc::new(host);
    let reply_delay_ms: u64 = env::var("REPLY_DELAY_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let mut rx = host.event_rx.lock().await;
    while let Some(event) = rx.recv().await {
        match event {
            Event::Ready { node_addr } => println!("PEER_JSON={node_addr}"),
            Event::RequestReceived { request_id, .. } => {
                // REPLY_DELAY_MS mimics the Elixir round trip the real server
                // takes before answering.
                let host = Arc::clone(&host);
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(reply_delay_ms)).await;
                    let _ = host
                        .send_response(request_id, mydia_p2p_core::MydiaResponse::Custom(vec![2]))
                        .await;
                });
            }
            _ => {}
        }
    }
}

async fn wait_for_connected(host: &Host) {
    let mut rx = host.event_rx.lock().await;
    while let Some(event) = rx.recv().await {
        if let Event::Connected { .. } = event {
            return;
        }
    }
    panic!("never connected");
}
