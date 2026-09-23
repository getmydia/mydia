//! What the event loop serves before its home relay is chosen.
//!
//! A player's first request used to sit behind `endpoint.online()`: every
//! command was held until a home relay was picked, about 3s on a real launch,
//! although the server's address already names a relay the dial can use.
//! These hosts have relays disabled, so their wait never ends inside a test.
#![cfg(feature = "test-introspection")]

use mydia_p2p_core::{Event, Host, HostConfig, MydiaRequest, MydiaResponse};
use std::sync::Arc;
use std::time::{Duration, Instant};

const TEST_TIMEOUT: Duration = Duration::from_secs(60);

fn test_config() -> HostConfig {
    HostConfig {
        bind_port: Some(0),
        ..Default::default()
    }
}

/// Waits for `Event::Ready` and returns the node's own EndpointAddr JSON.
async fn wait_for_ready(host: &Host) -> String {
    let mut rx = host.event_rx.lock().await;
    while let Some(event) = rx.recv().await {
        if let Event::Ready { node_addr } = event {
            return node_addr;
        }
    }
    panic!("host never became ready");
}

/// Drain `host.event_rx` for the rest of the test.
///
/// `LOG_TX` is a single process-wide slot the most recently constructed
/// `Host` in the whole test binary takes over, so a host that never reads
/// its events can still fill up on another test's log traffic. Once the
/// 100-item channel is full, a blocking `Event::Connected` send inside
/// `register_connection` has nothing to receive it and the event loop
/// stalls, which then stalls every `Command` reply the stalled host owes.
/// Mirrors the helper of the same name in `src/lib.rs`'s test module.
fn spawn_event_drain(host: &Host) {
    let event_rx = host.event_rx.clone();
    tokio::spawn(async move {
        let mut rx = event_rx.lock().await;
        while rx.recv().await.is_some() {}
    });
}

/// Answer `Custom` requests on `host`, echoing the payload back.
fn spawn_echo_responder(host: Arc<Host>) {
    tokio::spawn(async move {
        loop {
            let event = {
                let mut rx = host.event_rx.lock().await;
                rx.recv().await
            };
            match event {
                Some(Event::RequestReceived {
                    request: MydiaRequest::Custom(payload),
                    request_id,
                    ..
                }) => {
                    let _ = host
                        .send_response(request_id, MydiaResponse::Custom(payload))
                        .await;
                }
                Some(_) => continue,
                None => break,
            }
        }
    });
}

#[tokio::test]
async fn a_host_waiting_for_its_relay_still_dials_and_sends() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        a_host_waiting_for_its_relay_still_dials_and_sends_body(),
    )
    .await
    .expect("timed out: the dial or request never completed");
}

async fn a_host_waiting_for_its_relay_still_dials_and_sends_body() {
    let (responder, responder_id) = Host::new(test_config());
    let responder_addr = wait_for_ready(&responder).await;
    let responder = Arc::new(responder);
    spawn_echo_responder(responder.clone());

    // Dials over the responder's direct addresses: it has no relay to use.
    let (dialer, _dialer_id) = Host::new_without_relays(test_config());
    spawn_event_drain(&dialer);

    let started = Instant::now();
    dialer
        .dial(responder_addr)
        .await
        .expect("a dial should not wait for the dialer's home relay");
    let response = dialer
        .send_request(responder_id, MydiaRequest::Custom(b"early".to_vec()))
        .await
        .expect("a request should not wait for the dialer's home relay");
    let took = started.elapsed();

    assert_eq!(response, MydiaResponse::Custom(b"early".to_vec()));
    assert!(
        took < Duration::from_secs(5),
        "dial + request took {took:?}: the loop is still holding commands \
         until its relay wait ends (30s with relays disabled)"
    );

    // The one command that must still wait: the address the host publishes
    // has to carry its relay, so it is answered only once the wait ends.
    let node_addr = tokio::time::timeout(Duration::from_millis(500), dialer.get_node_addr()).await;
    assert!(
        node_addr.is_err(),
        "get_node_addr answered during the relay wait: {node_addr:?}"
    );
}

#[tokio::test]
async fn shutdown_during_the_relay_wait_is_prompt() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        shutdown_during_the_relay_wait_is_prompt_body(),
    )
    .await
    .expect("timed out: shutdown hung in the relay wait");
}

async fn shutdown_during_the_relay_wait_is_prompt_body() {
    let (host, _id) = Host::new_without_relays(test_config());
    spawn_event_drain(&host);
    let host = Arc::new(host);

    // Queued behind the wait, then released by the shutdown.
    let asker = host.clone();
    let queued = tokio::spawn(async move { asker.get_node_addr().await });
    tokio::time::sleep(Duration::from_millis(100)).await;

    let started = Instant::now();
    host.shutdown().await;
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "shutdown took {:?} during the relay wait",
        started.elapsed()
    );

    let addr = tokio::time::timeout(Duration::from_secs(5), queued)
        .await
        .expect("a get_node_addr queued in the wait must not outlive shutdown")
        .expect("the asking task panicked");
    assert_eq!(addr, "", "a queued get_node_addr answers empty on shutdown");
}
