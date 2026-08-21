// native/mydia_p2p_core/tests/two_node_control.rs
use mydia_p2p_core::{Event, Host, HostConfig, MydiaRequest, MydiaResponse};
use std::time::Duration;

/// This task already hit an unbounded 8+ minute hang once (see the module
/// doc on `two_hosts_exchange_a_request`). Some of the calls below are
/// transitively bounded by timeouts inside the crate — `wait_for_ready` by
/// the 30s relay-connect timeout in `run_event_loop`, `send_request`'s round
/// trip by the 30s response timeout in `handle_connection` — but
/// `Host::dial`'s `endpoint.connect(...)` (`handle_dial` in lib.rs) has no
/// bound anywhere in the crate. Rather than depend on that scattered,
/// implicit, and change-able set of internal timeouts, the test declares its
/// own explicit bound over the whole exchange.
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

fn test_config() -> HostConfig {
    HostConfig {
        relay_url: None,
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    }
}

/// Two hosts, one dials the other by its endpoint address and sends a request.
///
/// This is deliberately not a discovery test. Dialing by node ID alone depends
/// on n0's DNS, which is real network and would make CI flaky. The manual
/// check in step 5 covers that path.
///
/// Deviation from the brief: the brief's Step 1 draft used `MydiaRequest::Ping`
/// / `MydiaResponse::Pong` here. `handle_connection` in `lib.rs` special-cases
/// `Ping` to answer it directly on the stream, without ever emitting
/// `Event::RequestReceived` — so a responder task waiting on that event for a
/// `Ping` would block forever; confirmed empirically (an 8+ minute hang before
/// this was tracked down). `Custom` is not special-cased and exercises the
/// actual generic request/response path (store a `oneshot`, emit
/// `RequestReceived`, wait for `send_response`) that any future non-Ping
/// remote-control request will use, which is the thing this test exists to
/// prove out. Neither variant is new or renamed; both already exist on
/// `MydiaRequest`/`MydiaResponse`.
#[tokio::test]
async fn two_hosts_exchange_a_request() {
    tokio::time::timeout(TEST_TIMEOUT, two_hosts_exchange_a_request_body())
        .await
        .expect(
            "two_hosts_exchange_a_request timed out after 60s — dial() or send_request() \
             never completed; see the TEST_TIMEOUT doc comment for why this test carries its \
             own bound instead of relying on the crate's internal timeouts",
        );
}

async fn two_hosts_exchange_a_request_body() {
    let (responder, responder_id) = Host::new(test_config());
    let (dialer, _dialer_id) = Host::new(test_config());

    // Wait for the responder to be ready and learn its address.
    let responder_addr = wait_for_ready(&responder).await;

    // Answer inbound requests on the responder.
    let responder_handle = tokio::spawn(async move {
        let mut rx = responder.event_rx.lock().await;
        while let Some(event) = rx.recv().await {
            if let Event::RequestReceived { request_id, .. } = event {
                responder
                    .send_response(request_id, MydiaResponse::Custom(vec![2]))
                    .await
                    .expect("send_response failed");
                return;
            }
        }
    });

    dialer.dial(responder_addr).await.expect("dial failed");

    let response = dialer
        .send_request(responder_id, MydiaRequest::Custom(vec![1]))
        .await
        .expect("send_request failed");

    assert_eq!(response, MydiaResponse::Custom(vec![2]));
    responder_handle.await.unwrap();
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
