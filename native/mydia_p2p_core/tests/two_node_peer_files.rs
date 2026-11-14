#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "integration test crate"
)]

use mydia_p2p_core::{
    Event, Host, HostConfig, MydiaRequest, MydiaResponse, PeerFilesRequest, PeerFilesResponse,
    WireSharedAccount,
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
async fn two_hosts_exchange_peer_files_manifest() {
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

        let responder_handle = tokio::spawn(async move {
            {
                let mut rx = responder.event_rx.lock().await;
                while let Some(event) = rx.recv().await {
                    if let Event::RequestReceived {
                        peer,
                        request: MydiaRequest::PeerFiles(PeerFilesRequest::Manifest { auth_proof }),
                        request_id,
                    } = event
                    {
                        assert_eq!(peer, dialer_id);
                        assert_eq!(auth_proof, "deadbeef");
                        responder
                            .send_response(
                                request_id,
                                MydiaResponse::PeerFiles(PeerFilesResponse::Manifest {
                                    accounts: vec![account()],
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
                MydiaRequest::PeerFiles(PeerFilesRequest::Manifest {
                    auth_proof: "deadbeef".into(),
                }),
            )
            .await
            .unwrap();

        assert_eq!(
            response,
            MydiaResponse::PeerFiles(PeerFilesResponse::Manifest {
                accounts: vec![account()],
            })
        );

        let _responder = responder_handle.await.unwrap();
    })
    .await
    .unwrap();
}

fn account() -> WireSharedAccount {
    WireSharedAccount {
        account_id: "acct-1".into(),
        kind: "smb".into(),
        name: "Basement NAS".into(),
        dedupe_key: Some("smb://nas/media".into()),
        revision: 7,
    }
}
