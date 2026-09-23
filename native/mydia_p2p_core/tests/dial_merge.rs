//! Dials to one peer share one connect.
//!
//! Every `ensureConnected` caller in the player that finds the server not yet
//! connected sends its own `dial()`. Each used to start its own
//! `endpoint.connect`, so a launch opened 4 to 7 connections to one server.
#![cfg(feature = "test-introspection")]

use mydia_p2p_core::{Event, Host, HostConfig, MydiaRequest, MydiaResponse};
use std::sync::Arc;
use std::time::Duration;

const TEST_TIMEOUT: Duration = Duration::from_secs(60);

fn test_config() -> HostConfig {
    HostConfig {
        bind_port: Some(0),
        ..Default::default()
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

/// Drain `host.event_rx` for the rest of the test.
///
/// `LOG_TX` is a single process-wide slot the most recently constructed
/// `Host` in the whole test binary takes over, so a host that stops reading
/// its events after `wait_for_ready` can still fill up on another test's log
/// traffic. Once the 100-item channel is full, a blocking `Event::Connected`
/// send inside `register_connection` has nothing to receive it and the event
/// loop stalls, which then stalls every `Command` reply the stalled host owes.
/// Mirrors the helper of the same name in `src/lib.rs`'s test module.
fn spawn_event_drain(host: &Host) {
    let event_rx = host.event_rx.clone();
    tokio::spawn(async move {
        let mut rx = event_rx.lock().await;
        while rx.recv().await.is_some() {}
    });
}

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

/// A responder echoing `Custom` requests, and a dialer, both ready.
async fn ready_pair() -> (Arc<Host>, String, String, Host) {
    let (responder, responder_id) = Host::new(test_config());
    let (dialer, _dialer_id) = Host::new(test_config());
    let responder_addr = wait_for_ready(&responder).await;
    let _ = wait_for_ready(&dialer).await;
    spawn_event_drain(&dialer);
    let responder = Arc::new(responder);
    spawn_echo_responder(responder.clone());
    (responder, responder_id, responder_addr, dialer)
}

async fn within_timeout<F: std::future::Future<Output = ()>>(body: F) {
    tokio::time::timeout(TEST_TIMEOUT, body)
        .await
        .expect("timed out");
}

#[tokio::test]
async fn concurrent_dials_to_one_peer_share_a_connect() {
    within_timeout(async {
        let (_responder, _id, addr, dialer) = ready_pair().await;

        let (a, b, c) = tokio::join!(
            dialer.dial(addr.clone()),
            dialer.dial(addr.clone()),
            dialer.dial(addr.clone()),
        );
        a.expect("first dial");
        b.expect("second dial");
        c.expect("third dial");

        assert_eq!(
            dialer.debug_dial_count().await,
            1,
            "three concurrent dials to one peer should share one connect"
        );
    })
    .await;
}

#[tokio::test]
async fn a_dial_to_a_connected_peer_starts_no_connect() {
    within_timeout(async {
        let (_responder, _id, addr, dialer) = ready_pair().await;

        dialer.dial(addr.clone()).await.expect("first dial");
        dialer.dial(addr).await.expect("second dial");

        assert_eq!(
            dialer.debug_dial_count().await,
            1,
            "a dial to a peer that is already connected should reuse it"
        );
    })
    .await;
}

#[tokio::test]
async fn a_dial_and_a_send_to_one_peer_share_a_connect() {
    within_timeout(async {
        let (_responder, id, addr, dialer) = ready_pair().await;

        // `join!` polls in order, so the Dial command is queued before the
        // send: the send finds the dial in flight and waits on it.
        let (dialed, response) = tokio::join!(
            dialer.dial(addr),
            dialer.send_request(id, MydiaRequest::Custom(b"shared".to_vec())),
        );
        dialed.expect("dial");
        assert_eq!(
            response.expect("send"),
            MydiaResponse::Custom(b"shared".to_vec())
        );

        assert_eq!(
            dialer.debug_dial_count().await,
            1,
            "a send issued while a dial is in flight should wait on that dial"
        );
    })
    .await;
}

#[tokio::test]
async fn a_failed_dial_fails_every_waiter() {
    within_timeout(async {
        let (dialer, _id) = Host::new(test_config());
        let _ = wait_for_ready(&dialer).await;
        spawn_event_drain(&dialer);

        // A real key nobody holds, with no addresses: lookup finds nothing.
        let nobody = iroh::SecretKey::generate().public().to_string();
        let addr = format!(r#"{{"id":"{nobody}","addrs":[]}}"#);

        let (a, b) = tokio::join!(dialer.dial(addr.clone()), dialer.dial(addr));
        let a = a.expect_err("an unreachable peer cannot be dialed");
        let b = b.expect_err("an unreachable peer cannot be dialed");
        assert!(a.starts_with("Failed to connect:"), "got: {a}");
        assert!(b.starts_with("Failed to connect:"), "got: {b}");

        assert_eq!(dialer.debug_dial_count().await, 1);
    })
    .await;
}

/// A `Dial` carrying a full address must replace an addressless on-demand
/// dial already in flight for the same peer, rather than just join it: the
/// addressless attempt relies on discovery lookup and can fail or time out
/// even though the `Dial`'s address would have worked, and adding the
/// address as a hint does not help a connect already under way.
#[tokio::test]
async fn a_dial_with_addresses_replaces_an_addressless_dial_in_flight() {
    within_timeout(async {
        let (_responder, id, addr, dialer) = ready_pair().await;

        // No address hint added. `join!` polls its arguments in order, so
        // the request's on-demand (addressless) dial is queued first; the
        // `dial` that carries the address arrives while it is still
        // running and must supersede it.
        let (response, dialed) = tokio::join!(
            dialer.send_request(id, MydiaRequest::Custom(b"probe".to_vec())),
            dialer.dial(addr),
        );

        dialed.expect("the address-carrying dial should succeed");
        assert_eq!(
            response.expect("the queued request should complete"),
            MydiaResponse::Custom(b"probe".to_vec())
        );

        // The responder also publishes to discovery, so the addressless
        // connect might succeed on its own via pkarr -- the assertions
        // above hold either way. Either way two attempts were started: the
        // addressless one and the address-carrying replacement.
        assert_eq!(dialer.debug_dial_count().await, 2);
    })
    .await;
}
