#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "integration test crate"
)]

use mydia_p2p_core::{
    Event, Host, HostConfig, MydiaRequest, MydiaResponse, PeerSyncRequest, PeerSyncResponse,
    WirePeerMember, WirePinRecord, WireWatchRecord,
};
use std::time::Duration;

const TEST_TIMEOUT: Duration = Duration::from_mins(1);

fn test_config() -> HostConfig {
    HostConfig {
        relay_urls: Vec::new(),
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    }
}

#[tokio::test]
async fn two_hosts_exchange_peer_sync_messages() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let (responder, responder_id) = Host::new(test_config());
        let (dialer, dialer_id) = Host::new(test_config());

        let responder_addr = {
            let mut rx = responder.event_rx.lock().await;
            loop {
                if let Some(Event::Ready { node_addr }) = rx.recv().await {
                    break node_addr;
                }
            }
        };

        let responder_node_id = responder_id.clone();
        let responder_handle = tokio::spawn(async move {
            {
                let mut rx = responder.event_rx.lock().await;
                while let Some(event) = rx.recv().await {
                    if let Event::RequestReceived {
                        peer,
                        request:
                            MydiaRequest::PeerSync(PeerSyncRequest::Sync {
                                since_landed_ms, ..
                            }),
                        request_id,
                    } = event
                    {
                        assert_eq!(peer, dialer_id);
                        assert_eq!(since_landed_ms, 100);
                        responder
                            .send_response(
                                request_id,
                                MydiaResponse::PeerSync(PeerSyncResponse::SyncAck {
                                    roster: vec![WirePeerMember {
                                        node_id: responder_node_id,
                                        device_name: "Living Room TV".into(),
                                        platform: "android".into(),
                                        endpoint_addr_json: None,
                                        updated_at_ms: 500,
                                        revoked: false,
                                    }],
                                    watch_records: vec![WireWatchRecord {
                                        key: "tmdb:movie:603".into(),
                                        watched: true,
                                        position_seconds: None,
                                        duration_seconds: Some(7200),
                                        updated_at_ms: 500,
                                    }],
                                    pin_records: vec![WirePinRecord {
                                        key: "pin:m:fable of glass:2031".into(),
                                        group_key: "fable of glass:2031".into(),
                                        is_show: false,
                                        tmdb_id: Some(603),
                                        pinned: true,
                                        updated_at_ms: 500,
                                    }],
                                    peer_now_ms: 600,
                                }),
                            )
                            .await
                            .unwrap();
                        break;
                    }
                }
            }
            responder
        });

        dialer.dial(responder_addr).await.unwrap();

        let response = dialer
            .send_request(
                responder_id,
                MydiaRequest::PeerSync(PeerSyncRequest::Sync {
                    auth_proof: "deadbeef".into(),
                    sender_endpoint_addr_json: None,
                    roster: vec![],
                    since_landed_ms: 100,
                    watch_records: vec![],
                    pin_records: vec![],
                }),
            )
            .await
            .unwrap();

        match response {
            MydiaResponse::PeerSync(PeerSyncResponse::SyncAck {
                watch_records,
                pin_records,
                peer_now_ms,
                ..
            }) => {
                assert_eq!(watch_records.len(), 1);
                assert_eq!(watch_records[0].key, "tmdb:movie:603");
                assert_eq!(pin_records.len(), 1);
                assert_eq!(peer_now_ms, 600);
            }
            other => panic!("unexpected response: {other:?}"),
        }

        let _responder = responder_handle.await.unwrap();
    })
    .await
    .unwrap();
}
