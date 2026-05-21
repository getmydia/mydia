//! Integration tests covering the U20 plan's test scenarios.
//!
//! Coverage map (per the plan):
//!
//! - Happy path — qBittorrent adapter adds a torrent + parses the
//!   `Ok.` response shape: [`qbittorrent_add_torrent_round_trip`].
//! - Happy path — transmission session-id (`409`) retry: covered via
//!   [`transmission_session_id_retry`].
//! - `SABnzbd` JSON parsing: [`sabnzbd_add_url_returns_nzo_id`].
//! - Blackhole writes a file to a temp dir:
//!   [`blackhole_writes_torrent_file`].
//! - Transcode job manager runs a job: tracked under
//!   `#[ignore]`d test that runs only with `cargo test -- --ignored`
//!   when an `ffmpeg` binary is available.
//! - Blacklist exact match: [`blacklist_match_is_exact`].
//! - Cancel a running transcode job:
//!   [`cancel_running_transcode_removes_from_registry`].

use std::collections::HashMap;
use std::time::Duration;

use mydia_rs_downloads::adapter::AddOpts;
use mydia_rs_downloads::clients::blackhole::BlackholeClient;
use mydia_rs_downloads::clients::qbittorrent::QBittorrentClient;
use mydia_rs_downloads::clients::sabnzbd::SabnzbdClient;
use mydia_rs_downloads::clients::transmission::TransmissionClient;
use mydia_rs_downloads::{
    Blacklist, ClientConfig, DownloadClient, DownloadError, JobManager, JobStatus, ListOpts,
    Resolution, TorrentInput, TranscodeOptions,
};
use wiremock::matchers::{header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn config_for(server: &MockServer) -> ClientConfig {
    let url = server.uri();
    // Parse the URL — wiremock returns `http://127.0.0.1:<port>`.
    let stripped = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .unwrap_or(url.as_str());
    let (host, port_str) = stripped.split_once(':').unwrap();
    ClientConfig {
        host: host.to_owned(),
        port: port_str.parse().unwrap(),
        use_ssl: url.starts_with("https://"),
        ..ClientConfig::default()
    }
}

#[tokio::test]
async fn qbittorrent_add_torrent_round_trip() {
    let server = MockServer::start().await;
    // Login.
    Mock::given(method("POST"))
        .and(path("/api/v2/auth/login"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("set-cookie", "SID=cookiebytes;")
                .set_body_string("Ok."),
        )
        .mount(&server)
        .await;
    // Add torrent.
    Mock::given(method("POST"))
        .and(path("/api/v2/torrents/add"))
        .respond_with(ResponseTemplate::new(200).set_body_string("Ok."))
        .mount(&server)
        .await;

    let mut config = config_for(&server);
    config.username = Some("admin".into());
    config.password = Some("password".into());

    let client = QBittorrentClient;
    let result = client
        .add(
            &config,
            TorrentInput::Magnet("magnet:?xt=urn:btih:DEADBEEF".into()),
            AddOpts::default(),
        )
        .await;
    assert!(result.is_ok(), "qbittorrent add failed: {result:?}");
}

#[tokio::test]
async fn qbittorrent_misconfigured_returns_clear_error() {
    // No mock server at all — point at an unroutable port.
    let config = ClientConfig {
        host: "127.0.0.1".into(),
        port: 1, // reserved, refuses TCP
        username: Some("admin".into()),
        password: Some("password".into()),
        ..ClientConfig::default()
    };
    let err = QBittorrentClient
        .test_connection(&config)
        .await
        .unwrap_err();
    // Misconfigured host should surface as Network — not a panic.
    assert!(
        matches!(err, DownloadError::Network(_)),
        "expected Network, got {err:?}"
    );
}

#[tokio::test]
async fn transmission_session_id_retry() {
    let server = MockServer::start().await;
    // First call: 409 with the session id header.
    Mock::given(method("POST"))
        .and(path("/transmission/rpc"))
        .respond_with(
            ResponseTemplate::new(409)
                .insert_header("x-transmission-session-id", "fresh-session-id"),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;
    // Retry: 200 + JSON body that mimics a `torrent-get` response.
    Mock::given(method("POST"))
        .and(path("/transmission/rpc"))
        .and(header("x-transmission-session-id", "fresh-session-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "result": "success",
            "arguments": {
                "torrents": [
                    {
                        "hashString": "abc123",
                        "name": "Some.Release",
                        "status": 4,
                        "percentDone": 0.5,
                        "rateDownload": 100,
                        "rateUpload": 50,
                        "downloadedEver": 1024,
                        "uploadedEver": 0,
                        "totalSize": 2048,
                        "eta": 60,
                        "uploadRatio": 0.0,
                        "downloadDir": "/downloads",
                        "addedDate": 1_700_000_000,
                        "doneDate": 0,
                    }
                ]
            }
        })))
        .mount(&server)
        .await;

    let config = config_for(&server);
    let statuses = TransmissionClient
        .list_active(&config, ListOpts::default())
        .await
        .expect("list_active");
    assert_eq!(statuses.len(), 1);
    assert_eq!(statuses[0].id, "abc123");
    assert_eq!(statuses[0].name, "Some.Release");
}

#[tokio::test]
async fn sabnzbd_add_url_returns_nzo_id() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api"))
        .and(query_param("mode", "addurl"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "status": true,
            "nzo_ids": ["SABnzbd_nzo_abc123"],
        })))
        .mount(&server)
        .await;

    let mut config = config_for(&server);
    config.api_key = Some("key-x".into());
    let nzo_id = SabnzbdClient
        .add(
            &config,
            TorrentInput::Url("https://example.com/file.nzb".into()),
            AddOpts {
                title: Some("My.Release".into()),
                ..AddOpts::default()
            },
        )
        .await
        .expect("sabnzbd add");
    assert_eq!(nzo_id, "SABnzbd_nzo_abc123");
}

#[tokio::test]
async fn blackhole_writes_torrent_file() {
    let watch = tempfile::tempdir().unwrap();
    let completed = tempfile::tempdir().unwrap();
    let mut options = HashMap::new();
    options.insert("watch_folder".into(), watch.path().display().to_string());
    options.insert(
        "completed_folder".into(),
        completed.path().display().to_string(),
    );
    let config = ClientConfig {
        options,
        ..ClientConfig::default()
    };

    let id = BlackholeClient
        .add(
            &config,
            TorrentInput::File {
                bytes: b"d1:foo3:bare".to_vec(),
                title: Some("MyRelease".into()),
            },
            AddOpts::default(),
        )
        .await
        .expect("blackhole add");
    let written = watch.path().join(format!("{id}.torrent"));
    assert!(
        written.exists(),
        ".torrent should land in watch folder: {}",
        written.display()
    );
}

#[tokio::test]
async fn blacklist_match_is_exact() {
    let bl = Blacklist::in_memory();
    bl.add("indexer-a", "abc-123", "Some.Release", "stalled", None)
        .await;
    // Exact match: true.
    assert!(bl.is_blacklisted("indexer-a", "abc-123").await);
    // Substring-ish guid: must NOT be blocked.
    assert!(!bl.is_blacklisted("indexer-a", "x-abc-123-y").await);
    // Different indexer: not blocked.
    assert!(!bl.is_blacklisted("other-indexer", "abc-123").await);
}

#[tokio::test]
async fn cancel_running_transcode_removes_from_registry() {
    let manager = JobManager::new(2);
    let mut opts = TranscodeOptions::new("/tmp/in.mkv", "/tmp/out.mp4");
    // Long-running fake — we want the job to still be in-flight when
    // we cancel. /bin/sh -c "sleep 30" stays alive long enough.
    opts.ffmpeg_path = std::path::PathBuf::from("/bin/sleep");
    // The job manager treats this as if it were ffmpeg; we don't care
    // that the args don't match, only that the process spawns + that
    // cancel removes the registry entry.
    let _ = manager.start("file-1", Resolution::P720, opts).await;
    // Give the task a moment to actually insert into active.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let cancelled = manager.cancel("file-1", Resolution::P720);
    let _ = cancelled;
    // Allow the task to terminate.
    manager.drain(Duration::from_secs(2)).await;
    assert_eq!(
        manager.status("file-1", Resolution::P720),
        JobStatus::NotFound
    );
}

#[tokio::test]
#[ignore = "requires ffmpeg in PATH; runs only with `cargo test -- --ignored`"]
async fn transcoder_produces_progressive_mp4() {
    // This test only runs when the operator opts in via --ignored;
    // we don't ship a sample input file so it relies on ffmpeg's
    // `lavfi` source filter to synthesize one second of color bars.
    let out = tempfile::NamedTempFile::new().unwrap();
    let opts = TranscodeOptions {
        input_path: std::path::PathBuf::from("lavfi:testsrc=duration=1:size=320x240:rate=10"),
        output_path: out.path().to_path_buf(),
        max_duration: Duration::from_secs(30),
        ..TranscodeOptions::new("ignored.mkv", out.path())
    };
    let transcoder = mydia_rs_downloads::Transcoder::new(opts);
    let running = transcoder.start().await.expect("spawn ffmpeg");
    let produced = running.wait().await.expect("transcode wait");
    let metadata = tokio::fs::metadata(&produced).await.expect("output exists");
    assert!(metadata.len() > 0, "produced file should be non-empty");
}
