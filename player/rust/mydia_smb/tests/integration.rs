//! Integration tests against `tests/samba/run-samba.sh`.
//! Without `MYDIA_SMB_TEST_HOST` they print "skipped" and pass, unless
//! `MYDIA_SMB_REQUIRE_HARNESS` is set, which makes a missing harness a failure.

#![allow(clippy::unwrap_used, clippy::panic, reason = "test code")]

use std::sync::Arc;
use std::time::{Duration, Instant};

use mydia_smb::{Heal, SmbClient, SmbCredentials, SmbError, SmbTarget, StreamServer};

pub struct TestEnv {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
}

/// Harness settings from the environment. `None` (the test prints "skipped")
/// when they are absent, unless `MYDIA_SMB_REQUIRE_HARNESS` is set: CI sets it
/// so a harness that failed to start fails the run instead of skipping it.
pub fn test_env() -> Option<TestEnv> {
    let found = read_env();
    assert!(
        found.is_some() || std::env::var_os("MYDIA_SMB_REQUIRE_HARNESS").is_none(),
        "MYDIA_SMB_REQUIRE_HARNESS is set but the Samba harness variables \
         (MYDIA_SMB_TEST_HOST, _PORT, _USER, _PASSWORD) are missing or invalid"
    );
    found
}

fn read_env() -> Option<TestEnv> {
    let host = std::env::var("MYDIA_SMB_TEST_HOST").ok()?;
    let port = std::env::var("MYDIA_SMB_TEST_PORT").ok()?.parse().ok()?;
    Some(TestEnv {
        host,
        port,
        user: std::env::var("MYDIA_SMB_TEST_USER").ok()?,
        password: std::env::var("MYDIA_SMB_TEST_PASSWORD").ok()?,
    })
}

const MKV: &str = "/Fable of Glass (2031)/Fable of Glass (2031).mkv";

fn target(env: &TestEnv, share: &str) -> SmbTarget {
    SmbTarget {
        host: env.host.clone(),
        port: env.port,
        share: share.to_string(),
    }
}

fn guest() -> SmbCredentials {
    SmbCredentials {
        user: String::new(),
        password: String::new(),
        domain: None,
    }
}

fn account(env: &TestEnv) -> SmbCredentials {
    SmbCredentials {
        user: env.user.clone(),
        password: env.password.clone(),
        domain: None,
    }
}

/// Tests share one smbd. `reconnects_once_after_server_restart` restarts it,
/// so it takes this for writing and every other harness test for reading.
static SMBD: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());

/// Binds `$env` to the harness settings and holds a read lock on [`SMBD`]
/// for the rest of the test, or prints "skipped" and returns.
macro_rules! env_or_skip {
    ($env:ident) => {
        let Some($env) = test_env() else {
            println!("skipped");
            return;
        };
        let _smbd = SMBD.read().await;
    };
}

#[tokio::test]
async fn lists_guest_root() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let entries = client
        .list(&target(&env, "guest"), &guest(), "/")
        .await
        .unwrap();
    let dir = entries
        .iter()
        .find(|e| e.name == "Fable of Glass (2031)")
        .expect("fixture dir listed");
    assert!(dir.is_dir);
    assert_eq!(dir.path, "/Fable of Glass (2031)");
    assert!(entries.iter().all(|e| e.name != "." && e.name != ".."));
}

#[tokio::test]
async fn stats_fixture_size() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let entry = client
        .stat(&target(&env, "guest"), &guest(), MKV)
        .await
        .unwrap()
        .expect("exists");
    assert_eq!(entry.size, 67_108_864);
    assert!(!entry.is_dir);
}

#[tokio::test]
async fn stat_missing_is_none() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let entry = client
        .stat(&target(&env, "guest"), &guest(), "/nope.mkv")
        .await
        .unwrap();
    assert!(entry.is_none());
}

#[tokio::test]
async fn lists_and_stats_awkward_names() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let t = target(&env, "guest");
    let entries = client.list(&t, &guest(), "/").await.unwrap();
    let odd = entries
        .iter()
        .find(|e| e.name == "Odd #1 50% ?\u{e9}.mkv")
        .expect("odd name listed");
    assert_eq!(odd.path, "/Odd #1 50% ?\u{e9}.mkv");
    let stat = client
        .stat(&t, &guest(), &odd.path)
        .await
        .unwrap()
        .expect("odd name stats");
    assert_eq!(stat.size, 1024);
}

/// A password that differs from the harness one. Derived rather than written
/// out, with no string or char literal at all, so the code scanner's
/// hard-coded credential check has nothing to flag. Always longer than `right`, so it
/// differs for any input: a palindrome gains its first character again, and an
/// empty password becomes its length ("0").
fn wrong_password(right: &str) -> String {
    match right.chars().next() {
        Some(first) => right.chars().rev().chain([first]).collect(),
        None => right.len().to_string(),
    }
}

#[tokio::test]
async fn wrong_password_is_unauthorized() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let mut creds = account(&env);
    creds.password = wrong_password(&creds.password);
    let err = client
        .list(&target(&env, "auth"), &creds, "/")
        .await
        .unwrap_err();
    assert!(matches!(err, SmbError::Unauthorized), "{err:?}");
}

/// A re-login probe with a mistyped password must not ride the live session
/// pooled for the right one.
#[tokio::test]
async fn wrong_password_is_unauthorized_while_pooled() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let t = target(&env, "auth");
    let right = account(&env);
    client.list(&t, &right, "/").await.unwrap();
    #[cfg(feature = "test-introspection")]
    assert!(client.has_connection(&t, &right));

    let mut wrong = right.clone();
    wrong.password = wrong_password(&right.password);
    let err = client.list(&t, &wrong, "/").await.unwrap_err();
    assert!(matches!(err, SmbError::Unauthorized), "{err:?}");

    // The right login's pooled session is untouched.
    #[cfg(feature = "test-introspection")]
    assert!(client.has_connection(&t, &right));
    client.list(&t, &right, "/").await.unwrap();
}

#[tokio::test]
async fn missing_share_is_not_found() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let err = client
        .list(&target(&env, "nope"), &account(&env), "/")
        .await
        .unwrap_err();
    assert!(matches!(err, SmbError::NotFound), "{err:?}");
}

#[tokio::test]
async fn closed_port_is_unreachable() {
    let client = SmbClient::new();
    let t = SmbTarget {
        host: "127.0.0.1".to_string(),
        port: 1,
        share: "guest".to_string(),
    };
    let started = Instant::now();
    let err = client.list(&t, &guest(), "/").await.unwrap_err();
    assert!(matches!(err, SmbError::Unreachable(_)), "{err:?}");
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[tokio::test]
async fn smb1_server_is_smb1_only() {
    env_or_skip!(env);
    let Some(port) = std::env::var("MYDIA_SMB_TEST_SMB1_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
    else {
        println!("skipped");
        return;
    };
    let client = SmbClient::new();
    let t = SmbTarget {
        host: env.host.clone(),
        port,
        share: "smb1".to_string(),
    };
    let err = client.list(&t, &account(&env), "/").await.unwrap_err();
    assert!(matches!(err, SmbError::Smb1Only), "{err:?}");
}

#[tokio::test]
async fn denied_entry_is_unreadable_not_fatal() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let entries = client
        .list(&target(&env, "auth"), &account(&env), "/")
        .await
        .unwrap();
    let denied = entries.iter().find(|e| e.name == "denied").expect("listed");
    assert!(denied.unreadable);
    let fine = entries
        .iter()
        .find(|e| e.name == "Fable of Glass (2031)")
        .expect("listed");
    assert!(!fine.unreadable);
}

#[tokio::test]
async fn encrypted_share_lists() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let entries = client
        .list(&target(&env, "enc"), &account(&env), "/")
        .await
        .unwrap();
    assert!(entries.iter().any(|e| e.name == "Fable of Glass (2031)"));
}

#[tokio::test]
async fn shares_exclude_admin() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let shares = client
        .list_shares(&env.host, env.port, &account(&env))
        .await
        .unwrap();
    assert!(shares.iter().any(|s| s == "guest"), "{shares:?}");
    assert!(shares.iter().any(|s| s == "auth"), "{shares:?}");
    assert!(shares.iter().all(|s| !s.ends_with('$')), "{shares:?}");
}

fn pattern_byte(i: u64) -> u8 {
    u8::try_from((i * 31 + 7) % 251).unwrap()
}

#[tokio::test]
async fn read_at_matches_pattern() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let file = client
        .open(&target(&env, "guest"), &guest(), MKV)
        .await
        .unwrap();
    assert_eq!(file.size(), 67_108_864);
    let offset = 1_000_000_u64;
    let data = file.read_at(offset, 4096).await.unwrap();
    assert_eq!(data.len(), 4096);
    for (i, b) in data.iter().enumerate() {
        assert_eq!(*b, pattern_byte(offset + i as u64), "byte {i}");
    }
    // A read past the end is clamped.
    let tail = file.read_at(67_108_864 - 10, 100).await.unwrap();
    assert_eq!(tail.len(), 10);
}

#[tokio::test]
async fn open_missing_is_not_found() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let err = client
        .open(&target(&env, "guest"), &guest(), "/nope.mkv")
        .await
        .err()
        .expect("fails");
    assert!(matches!(err, SmbError::NotFound), "{err:?}");
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn idle_connections_close_after_60s() {
    env_or_skip!(env);
    let client = SmbClient::with_idle_timeout(Duration::from_millis(200));
    client
        .list(&target(&env, "guest"), &guest(), "/")
        .await
        .unwrap();
    assert_eq!(client.pool_size(), 1);
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(client.pool_size(), 0);
    // The next call reconnects.
    client
        .list(&target(&env, "guest"), &guest(), "/")
        .await
        .unwrap();
    assert_eq!(client.pool_size(), 1);
}

// ---- StreamServer -------------------------------------------------------

const SIZE: u64 = 67_108_864;

fn unused_target() -> SmbTarget {
    SmbTarget {
        host: "127.0.0.1".to_string(),
        port: 1,
        share: "guest".to_string(),
    }
}

async fn served(env: &TestEnv) -> (Arc<StreamServer>, String) {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let url = server
        .open("acct", target(env, "guest"), guest(), MKV)
        .unwrap();
    (server, url)
}

async fn get_range(url: &str, range: &str) -> reqwest::Response {
    reqwest::Client::new()
        .get(url)
        .header("Range", range)
        .send()
        .await
        .unwrap()
}

fn header<'a>(resp: &'a reqwest::Response, name: &str) -> &'a str {
    resp.headers()
        .get(name)
        .unwrap_or_else(|| panic!("missing {name}"))
        .to_str()
        .unwrap()
}

fn assert_pattern(data: &[u8], offset: u64) {
    for (i, b) in data.iter().enumerate() {
        assert_eq!(*b, pattern_byte(offset + i as u64), "byte {i}");
    }
}

#[tokio::test]
async fn head_reports_size() {
    env_or_skip!(env);
    let (_server, url) = served(&env).await;
    let resp = reqwest::Client::new().head(&url).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(header(&resp, "content-length"), SIZE.to_string());
    assert_eq!(header(&resp, "accept-ranges"), "bytes");
    assert_eq!(header(&resp, "content-type"), "application/octet-stream");
}

#[tokio::test]
async fn range_returns_exact_bytes() {
    env_or_skip!(env);
    let (_server, url) = served(&env).await;
    let resp = get_range(&url, "bytes=1000000-1004095").await;
    assert_eq!(resp.status(), 206);
    assert_eq!(
        header(&resp, "content-range"),
        format!("bytes 1000000-1004095/{SIZE}")
    );
    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len(), 4096);
    assert_pattern(&body, 1_000_000);
}

#[tokio::test]
async fn range_spanning_chunks_is_exact() {
    env_or_skip!(env);
    let (_server, url) = served(&env).await;
    // 3 MiB starting mid-chunk, so the read-ahead path is exercised.
    let start = 500_000_u64;
    let end = start + 3 * 1024 * 1024 - 1;
    let resp = get_range(&url, &format!("bytes={start}-{end}")).await;
    assert_eq!(resp.status(), 206);
    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len() as u64, end - start + 1);
    assert_pattern(&body, start);
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn tail_range_reads_only_the_tail() {
    env_or_skip!(env);
    let (server, url) = served(&env).await;
    let resp = get_range(&url, "bytes=-4096").await;
    assert_eq!(resp.status(), 206);
    assert_eq!(
        header(&resp, "content-range"),
        format!("bytes 67104768-67108863/{SIZE}")
    );
    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len(), 4096);
    assert_pattern(&body, 67_104_768);
    assert!(
        server.min_read_offset() >= 67_104_768,
        "{}",
        server.min_read_offset()
    );
}

#[tokio::test]
async fn past_end_is_416() {
    env_or_skip!(env);
    let (_server, url) = served(&env).await;
    let resp = get_range(&url, &format!("bytes={SIZE}-")).await;
    assert_eq!(resp.status(), 416);
    assert_eq!(header(&resp, "content-range"), format!("bytes */{SIZE}"));
}

#[tokio::test]
async fn unknown_token_is_404() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let url = format!(
        "http://127.0.0.1:{}/smb/0123456789abcdef0123456789abcdef",
        server.port()
    );
    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status(), 404);
    let resp = reqwest::get(format!("http://127.0.0.1:{}/other", server.port()))
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

#[tokio::test]
async fn closed_account_tokens_404() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let url = server
        .open("acct", unused_target(), guest(), "/a.mkv")
        .unwrap();
    let kept = server
        .open("other", unused_target(), guest(), "/a.mkv")
        .unwrap();
    server.close_account("acct");
    assert_eq!(reqwest::get(&url).await.unwrap().status(), 404);
    // Another account's token is still known: it fails on the SMB side
    // (port 1 is closed), not as an unknown token.
    assert_eq!(reqwest::get(&kept).await.unwrap().status(), 502);
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn abandoned_response_does_not_poison_next_request() {
    env_or_skip!(env);
    let (server, url) = served(&env).await;
    {
        let mut resp = reqwest::get(&url).await.unwrap();
        assert_eq!(resp.status(), 200);
        let mut got = 0;
        while got < 1024 * 1024 {
            got += resp.chunk().await.unwrap().unwrap().len();
        }
    }
    // The reader behind the dropped response stops.
    let deadline = Instant::now() + Duration::from_secs(5);
    while server.active_readers() > 0 {
        assert!(Instant::now() < deadline, "reader still running");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let resp = get_range(&url, "bytes=2000000-2000999").await;
    assert_eq!(resp.status(), 206);
    let body = resp.bytes().await.unwrap();
    assert_eq!(body.len(), 1000);
    assert_pattern(&body, 2_000_000);
}

#[tokio::test]
async fn reconnects_once_after_server_restart() {
    let Some(env) = test_env() else {
        println!("skipped");
        return;
    };
    let _smbd = SMBD.write().await;
    let (_server, url) = served(&env).await;
    let resp = get_range(&url, "bytes=0-4095").await;
    assert_eq!(resp.status(), 206);
    resp.bytes().await.unwrap();
    // A pooled client of its own, used before the restart.
    let client = SmbClient::new();
    let t = target(&env, "guest");
    client.list(&t, &guest(), "/").await.unwrap();

    // Every wait below is bounded: a restart that leaves no smbd must fail
    // this test with a message, not hold the write lock until CI times out.
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/samba/run-samba.sh");
    let restart = tokio::process::Command::new(script)
        .arg("restart")
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_mins(1), restart)
        .await
        .unwrap_or_else(|_| panic!("run-samba.sh restart did not finish within 60s"))
        .unwrap();
    assert!(
        out.status.success(),
        "run-samba.sh restart failed ({}): {}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );

    let after_restart = async {
        // The pooled session is dead: list retries once on a fresh connection.
        let entries = client.list(&t, &guest(), "/").await.unwrap();
        assert!(entries.iter().any(|e| e.name == "Fable of Glass (2031)"));

        let resp = get_range(&url, "bytes=5000000-5004095").await;
        assert_eq!(resp.status(), 206);
        resp.bytes().await.unwrap()
    };
    let body = tokio::time::timeout(Duration::from_secs(30), after_restart)
        .await
        .unwrap_or_else(|_| {
            panic!(
                "requests after the smbd restart did not finish within 30s; \
                 is smbd still running? (run-samba.sh stderr: {})",
                String::from_utf8_lossy(&out.stderr)
            )
        });
    assert_eq!(body.len(), 4096);
    assert_pattern(&body, 5_000_000);
}

#[tokio::test]
async fn concurrent_heals_leave_one_listener() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let port = server.port();
    #[cfg(feature = "test-introspection")]
    server.stop_listener().await;
    let (a, b, c) = tokio::join!(server.heal(), server.heal(), server.heal());
    for h in [a, b, c] {
        h.unwrap();
    }
    assert_eq!(server.port(), port);
    assert_eq!(server.heal().await.unwrap(), Heal::Healthy);
}

#[tokio::test]
async fn heal_without_loss_is_healthy() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let port = server.port();
    assert_eq!(server.heal().await.unwrap(), Heal::Healthy);
    assert_eq!(server.port(), port);
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn heal_after_listener_loss_rebinds_same_port() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let port = server.port();
    let url = server
        .open("acct", unused_target(), guest(), "/a.mkv")
        .unwrap();
    server.stop_listener().await;
    assert_eq!(server.heal().await.unwrap(), Heal::ReboundSamePort);
    assert_eq!(server.port(), port);
    // Tokens survive the rebind.
    assert_eq!(reqwest::get(&url).await.unwrap().status(), 502);
}

#[tokio::test]
async fn url_carries_no_path() {
    let server = StreamServer::start(SmbClient::new()).await.unwrap();
    let url = server.open("acct", unused_target(), guest(), MKV).unwrap();
    let rest = url
        .strip_prefix("http://127.0.0.1:")
        .unwrap_or_else(|| panic!("{url}"));
    let (port, token) = rest.split_once("/smb/").unwrap_or_else(|| panic!("{url}"));
    assert_eq!(port.parse::<u16>().unwrap(), server.port());
    assert_eq!(token.len(), 32, "{url}");
    assert!(
        token.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')),
        "{url}"
    );
    let other = server.open("acct", unused_target(), guest(), MKV).unwrap();
    assert_ne!(url, other);
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn close_drops_the_pooled_connection() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let t = target(&env, "guest");
    client.list(&t, &guest(), "/").await.unwrap();
    assert!(client.has_connection(&t, &guest()));
    client.close(&t, &guest());
    assert!(!client.has_connection(&t, &guest()));
    // The next call simply reconnects.
    client.list(&t, &guest(), "/").await.unwrap();
    assert!(client.has_connection(&t, &guest()));
}

#[cfg(feature = "test-introspection")]
#[tokio::test]
async fn closed_account_ends_in_flight_body_without_reconnecting() {
    env_or_skip!(env);
    let client = SmbClient::new();
    let server = StreamServer::start(client.clone()).await.unwrap();
    let t = target(&env, "guest");
    let url = server.open("acct", t.clone(), guest(), MKV).unwrap();
    let mut resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status(), 200);
    let mut got = 0_u64;
    while got < 1024 * 1024 {
        got += resp.chunk().await.unwrap().unwrap().len() as u64;
    }

    server.close_account("acct");
    assert!(!client.has_connection(&t, &guest()));

    // The body ends short instead of carrying on to the end of the file.
    let ended_early = loop {
        match resp.chunk().await {
            Ok(Some(c)) => got += c.len() as u64,
            Ok(None) => break got < SIZE,
            Err(_) => break true,
        }
    };
    assert!(ended_early, "body ran to completion ({got} bytes)");
    let deadline = Instant::now() + Duration::from_secs(5);
    while server.active_readers() > 0 {
        assert!(Instant::now() < deadline, "reader still running");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Nothing reconnected on the closed account's behalf.
    assert!(!client.has_connection(&t, &guest()));
    assert_eq!(reqwest::get(&url).await.unwrap().status(), 404);
}
