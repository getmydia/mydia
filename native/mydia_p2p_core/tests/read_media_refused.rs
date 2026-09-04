//! `ReadMedia` is refused by the core before it can reach a host.
//!
//! The Phoenix handler behind this request read whatever absolute path the
//! peer named, with no auth token anywhere on the path (getmydia/mydia#687).
//! Nothing has ever sent one: the Flutter player has never referenced the
//! request in any commit, and mydia-rs already answers it with an error of
//! its own. The variant stays on the wire so a peer that does send one gets a
//! clean refusal rather than a dropped stream, and this pins that refusal.

use mydia_p2p_core::{blocking, Host, HostConfig, MydiaRequest, MydiaResponse, ReadMediaRequest};
use std::time::Duration;

/// The endpoint binds and publishes its address asynchronously, so poll
/// rather than sleeping a fixed amount. Same helper as `host_loopback.rs`;
/// integration tests are separate binaries and cannot share it.
fn wait_for_addr(host: &Host) -> String {
    for _ in 0..100 {
        let addr = blocking::get_node_addr(host);
        if !addr.is_empty() && addr != "null" {
            return addr;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("host never published an endpoint address");
}

#[test]
fn read_media_is_refused_without_reading_the_file() {
    let rt = tokio::runtime::Runtime::new().expect("test runtime");

    // A file the server process can certainly read. Asking for a path that
    // does not exist would pass even if the refusal were reordered behind a
    // filesystem check, which is exactly the regression this guards against.
    let probe = std::env::temp_dir().join(format!("mydia_read_media_probe_{}", std::process::id()));
    let secret = b"this content must never reach a peer";
    std::fs::write(&probe, secret).expect("write probe file");

    let (server, server_id) = Host::new(HostConfig::default());
    let (client, _client_id) = Host::new(HostConfig::default());

    let server_addr = wait_for_addr(&server);
    blocking::dial(&client, server_addr).expect("dial should succeed");

    let request = MydiaRequest::ReadMedia(ReadMediaRequest {
        file_path: probe.to_string_lossy().into_owned(),
        offset: 0,
        length: secret.len() as u32,
    });

    let response = rt
        .block_on(async {
            tokio::time::timeout(
                Duration::from_secs(10),
                client.send_request(server_id.clone(), request),
            )
            .await
        })
        .expect("read_media timed out; the core never answered it")
        .expect("read_media returned a transport error");

    let _ = std::fs::remove_file(&probe);

    match response {
        MydiaResponse::Error(message) => {
            assert_eq!(message, "unsupported_request_type");
        }
        MydiaResponse::MediaChunk(bytes) => {
            panic!("the core served {} bytes of a peer-named file", bytes.len());
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
}
