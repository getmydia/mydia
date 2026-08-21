//! Manual check for Task 1, Step 5: does `presets::N0` discovery let a
//! dialer reach a peer given only its node ID, with no address exchanged
//! out of band?
//!
//! This is a thin wrapper over the same `Host` calls the
//! `two_node_control` integration test uses (`Host::new`, `dial`,
//! `send_request`), except the dialer is handed only the responder's node
//! ID string, never its `EndpointAddr` JSON.
//!
//! `Host::dial` still takes a JSON string (that is the existing API surface;
//! this spike does not change it), so the dialer wraps the bare ID in the
//! minimal envelope `{"id":"<node-id>","addrs":[]}` — an empty `addrs` set,
//! i.e. no relay URL and no direct IP address. That is the "no address
//! JSON" case: everything needed to actually reach the peer, beyond its
//! identity, has to come from discovery.
//!
//! Usage, two machines on different networks:
//!
//! ```text
//! # machine A
//! cargo run --example dial_by_node_id -- --listen
//! # prints "node id: <id>", then waits for one request
//!
//! # machine B
//! cargo run --example dial_by_node_id -- <node-id>
//! ```
//!
//! A local two-process run (both on this machine, real network egress for
//! DNS discovery and relay) is also informative and is what Task 1 records
//! in its report, since a genuine two-machine run isn't available here.

use mydia_p2p_core::{Event, Host, HostConfig, MydiaRequest, MydiaResponse};
use std::env;

fn host_config() -> HostConfig {
    HostConfig {
        relay_url: None,
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args: Vec<String> = env::args().skip(1).collect();

    let (host, node_id) = Host::new(host_config());
    let _own_addr = wait_for_ready(&host).await;

    match args.first().map(String::as_str) {
        Some("--listen") => {
            println!("node id: {node_id}");
            println!("waiting for a request...");
            answer_one_request(&host).await;
        }
        Some(target_id) => {
            println!("dialing node id only (no address JSON): {target_id}");

            // Deliberately empty `addrs`: this is the thing Step 5 tests.
            // Everything needed to reach the peer beyond its ID has to come
            // from presets::N0 discovery.
            let addr_json = format!(r#"{{"id":"{target_id}","addrs":[]}}"#);

            match host.dial(addr_json).await {
                Ok(()) => println!("dial() returned Ok"),
                Err(e) => {
                    eprintln!("dial failed: {e}");
                    std::process::exit(1);
                }
            }

            // `Custom` rather than `Ping`: `handle_connection` in lib.rs
            // auto-answers `Ping` on the stream without ever emitting
            // `Event::RequestReceived`, so the listener's `answer_one_request`
            // below would never run. `Custom` exercises the actual generic
            // request/response event path.
            match host
                .send_request(target_id.to_string(), MydiaRequest::Custom(vec![1]))
                .await
            {
                Ok(MydiaResponse::Custom(bytes)) => {
                    println!("SUCCESS: got {bytes:?} back from {target_id} via node-ID-only dial")
                }
                Ok(other) => println!("unexpected response: {other:?}"),
                Err(e) => {
                    eprintln!("send_request failed: {e}");
                    std::process::exit(1);
                }
            }
        }
        None => {
            eprintln!("usage: dial_by_node_id -- --listen | <node-id>");
            std::process::exit(2);
        }
    }
}

async fn wait_for_ready(host: &Host) -> String {
    let mut rx = host.event_rx.lock().await;
    while let Some(event) = rx.recv().await {
        if let Event::Ready { node_addr } = event {
            return node_addr;
        }
    }
    panic!("host never became ready");
}

async fn answer_one_request(host: &Host) {
    let mut rx = host.event_rx.lock().await;
    while let Some(event) = rx.recv().await {
        if let Event::RequestReceived {
            request_id, peer, ..
        } = event
        {
            println!("got request from {peer}, answering");
            host.send_response(request_id, MydiaResponse::Custom(vec![2]))
                .await
                .expect("send_response failed");

            // `send_response` only enqueues the response on the crate's
            // internal command channel; it returns as soon as that send
            // succeeds, not once the reply has actually gone out on the
            // wire. That write happens in a task on the crate's own shared
            // background runtime. If `main` returns right away, the process
            // exits and that runtime — and the in-flight write with it — is
            // torn down before it flushes. Linger long enough for the write
            // (and the dialer's read) to complete before letting the process
            // exit.
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            return;
        }
    }
}
