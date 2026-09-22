//! Dialing by bare node ID, seeded through the address hint channel.
//!
//! These tests never touch n0's DNS. Each dialer is handed the responder's
//! address through `Host::add_address_hint` first, so the node-ID path under
//! test resolves locally. `two_node_control.rs` covers dialing by address.

use mydia_p2p_core::{Event, Host, HostConfig, MydiaRequest, MydiaResponse};
use std::time::Duration;

/// Every test carries its own bound: `endpoint.connect` has no timeout of its
/// own inside the crate, so a regression would otherwise hang CI.
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

fn test_config() -> HostConfig {
    HostConfig {
        relay_urls: Vec::new(),
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
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

/// A valid Ed25519 identity with no endpoint behind it, ever.
///
/// Not a second `Host`: `Host::new` starts a live node that binds, joins a
/// relay and publishes a pkarr record, so it is reachable by node ID within
/// seconds. CI proved that the hard way, resolving one through discovery and
/// connecting to it over the relay while this test was asserting it could not
/// be reached.
///
/// The key is random per call, not fixed. It used to be `[7u8; 32]`, the
/// same bytes a test in `src/lib.rs` gave a live `Host`, and `cargo test` runs
/// that test seconds before this file. Twice on 2026-09-21 the dial resolved
/// through discovery to that host and connected, so "a black-holed peer
/// should not connect" failed. Any fixed key is shared with every other run
/// using the public relay at the same moment.
fn unreachable_node_id() -> String {
    iroh::SecretKey::generate().public().to_string()
}

/// The EndpointAddr JSON a roster entry produces: a node ID and nothing else.
fn node_addr_json_without_addrs(node_id: &str) -> String {
    format!(r#"{{"id":"{node_id}","addrs":[]}}"#)
}

#[tokio::test]
async fn a_hinted_peer_is_dialable_by_node_id_alone() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        a_hinted_peer_is_dialable_by_node_id_alone_body(),
    )
    .await
    .expect("timed out: add_address_hint or dial never completed");
}

async fn a_hinted_peer_is_dialable_by_node_id_alone_body() {
    let (responder, responder_id) = Host::new(test_config());
    let (dialer, _dialer_id) = Host::new(test_config());

    let responder_addr = wait_for_ready(&responder).await;
    let _ = wait_for_ready(&dialer).await;

    dialer
        .add_address_hint(responder_addr)
        .await
        .expect("the hint should be accepted");

    // The addrs are empty: only the hint can resolve this.
    dialer
        .dial(node_addr_json_without_addrs(&responder_id))
        .await
        .expect("a hinted peer should be dialable by node ID alone");
}
/// A dial that cannot succeed must not freeze the loop.
///
/// Before this, `handle_dial` was awaited inside the select arm, so one peer
/// that never answers blocked every other command for the whole connect
/// attempt. The assertion is not that the dial fails (it does) but that an
/// unrelated command is answered promptly while it is still in flight.
///
/// Two details are load-bearing, both measured rather than assumed:
///
///   * The peer ID must be a real Ed25519 public key. A made-up one like
///     `0000...0001` is rejected by `endpoint_addr_from_json` in well under a
///     millisecond, so the dial never reaches the network and this test
///     passes with or without the fix.
///   * The address must black-hole rather than refuse. Pointed at TEST-NET-1,
///     iroh's connect runs its full 30 second timeout, and pre-fix
///     `get_node_addr` was measured waiting 29.95s of it. Post-fix it answers
///     in under a millisecond.
#[tokio::test]
async fn an_unreachable_dial_does_not_block_other_commands() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        an_unreachable_dial_does_not_block_other_commands_body(),
    )
    .await
    .expect("timed out: the event loop stalled behind a dial");
}

async fn an_unreachable_dial_does_not_block_other_commands_body() {
    let (dialer, _dialer_id) = Host::new(test_config());
    let _ = wait_for_ready(&dialer).await;

    // TEST-NET-1 (RFC 5737), reserved for documentation. Packets to it are
    // dropped rather than refused, so the handshake runs to its timeout.
    let blackhole = format!(
        r#"{{"id":"{}","addrs":[{{"Ip":"192.0.2.1:9"}}]}}"#,
        unreachable_node_id()
    );

    let dialing = dialer.dial(blackhole);
    let answering = async {
        // Let the loop pick the dial up first, then time how long an
        // unrelated command takes. Two seconds is far beyond the sub-
        // millisecond answer a free loop gives, and far below the 30 seconds
        // a blocked one costs.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let asked_at = std::time::Instant::now();
        let addr = dialer.get_node_addr().await;
        (addr, asked_at.elapsed())
    };

    let (dial_result, (addr, waited)) = tokio::join!(dialing, answering);

    assert!(
        dial_result.is_err(),
        "a black-holed peer should not connect"
    );
    assert!(
        !addr.is_empty(),
        "the loop should still answer other commands"
    );
    assert!(
        waited < Duration::from_secs(2),
        "get_node_addr waited {waited:?} on the in-flight dial, so the loop is \
         still serving dials inline"
    );
}

/// Answer \`Custom\` requests on \`host\`, echoing the payload back.
///
/// \`Ping\` is answered inside \`handle_connection\` and never reaches an event,
/// so it cannot be used here. \`Custom\` exercises the real generic path.
fn spawn_echo_responder(host: std::sync::Arc<Host>) {
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
async fn a_send_to_an_unconnected_peer_dials_it() {
    tokio::time::timeout(TEST_TIMEOUT, a_send_to_an_unconnected_peer_dials_it_body())
        .await
        .expect("timed out: the send never produced a connection");
}

async fn a_send_to_an_unconnected_peer_dials_it_body() {
    let (responder, responder_id) = Host::new(test_config());
    let (sender, _sender_id) = Host::new(test_config());

    let responder_addr = wait_for_ready(&responder).await;
    let _ = wait_for_ready(&sender).await;
    let responder = std::sync::Arc::new(responder);
    spawn_echo_responder(responder.clone());

    sender
        .add_address_hint(responder_addr)
        .await
        .expect("the hint should be accepted");

    // No dial anywhere in this test: the send is expected to establish the
    // connection itself, from a bare node ID, exactly as a probe does.
    let response = sender
        .send_request(responder_id, MydiaRequest::Custom(b"probe".to_vec()))
        .await
        .expect("a send to an unconnected peer should dial and succeed");

    assert_eq!(response, MydiaResponse::Custom(b"probe".to_vec()));
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn two_sends_to_one_unconnected_peer_share_a_dial() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        two_sends_to_one_unconnected_peer_share_a_dial_body(),
    )
    .await
    .expect("timed out: concurrent sends never completed");
}

#[cfg(feature = "test-introspection")]
async fn two_sends_to_one_unconnected_peer_share_a_dial_body() {
    let (responder, responder_id) = Host::new(test_config());
    let (sender, _sender_id) = Host::new(test_config());

    let responder_addr = wait_for_ready(&responder).await;
    let _ = wait_for_ready(&sender).await;
    let responder = std::sync::Arc::new(responder);
    spawn_echo_responder(responder.clone());

    sender.add_address_hint(responder_addr).await.unwrap();

    let first = sender.send_request(responder_id.clone(), MydiaRequest::Custom(b"one".to_vec()));
    let second = sender.send_request(responder_id.clone(), MydiaRequest::Custom(b"two".to_vec()));
    let (first, second) = tokio::join!(first, second);

    assert_eq!(first.unwrap(), MydiaResponse::Custom(b"one".to_vec()));
    assert_eq!(second.unwrap(), MydiaResponse::Custom(b"two".to_vec()));
    assert_eq!(
        sender.debug_dial_count().await,
        1,
        "concurrent sends to one peer should share a single dial"
    );
}

#[tokio::test]
async fn a_send_to_an_unreachable_peer_reports_the_dial_failure() {
    tokio::time::timeout(
        TEST_TIMEOUT,
        a_send_to_an_unreachable_peer_reports_the_dial_failure_body(),
    )
    .await
    .expect("timed out: the failing send never returned");
}

async fn a_send_to_an_unreachable_peer_reports_the_dial_failure_body() {
    let (sender, _sender_id) = Host::new(test_config());
    let _ = wait_for_ready(&sender).await;

    // No hint for it either, so discovery has nothing to answer with and the
    // dial fails. A made-up node ID would not do: it fails at key parsing
    // with `invalid node ID:` and never dials at all.
    let error = sender
        .send_request(
            unreachable_node_id(),
            MydiaRequest::Custom(b"probe".to_vec()),
        )
        .await
        .expect_err("an unreachable peer cannot answer");

    assert!(
        error.starts_with("dial_failed:"),
        "a controller distinguishes an unreachable target by this prefix, got: {error}"
    );
}
