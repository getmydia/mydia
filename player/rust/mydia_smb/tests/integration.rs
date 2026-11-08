//! Integration tests against `tests/samba/run-samba.sh`.
//! Without `MYDIA_SMB_TEST_HOST` they print "skipped" and pass.

#![allow(clippy::unwrap_used, reason = "test code")]

use std::time::{Duration, Instant};

use mydia_smb::{SmbClient, SmbCredentials, SmbError, SmbTarget};

pub struct TestEnv {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
}

pub fn test_env() -> Option<TestEnv> {
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

macro_rules! env_or_skip {
    () => {
        match test_env() {
            Some(env) => env,
            None => {
                println!("skipped");
                return;
            }
        }
    };
}

#[tokio::test]
async fn lists_guest_root() {
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
    let env = env_or_skip!();
    let client = SmbClient::new();
    let entry = client
        .stat(&target(&env, "guest"), &guest(), "/nope.mkv")
        .await
        .unwrap();
    assert!(entry.is_none());
}

#[tokio::test]
async fn lists_and_stats_awkward_names() {
    let env = env_or_skip!();
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

#[tokio::test]
async fn wrong_password_is_unauthorized() {
    let env = env_or_skip!();
    let client = SmbClient::new();
    let mut creds = account(&env);
    creds.password = "definitely-wrong".to_string();
    let err = client
        .list(&target(&env, "auth"), &creds, "/")
        .await
        .unwrap_err();
    assert!(matches!(err, SmbError::Unauthorized), "{err:?}");
}

#[tokio::test]
async fn missing_share_is_not_found() {
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
    let env = env_or_skip!();
    let client = SmbClient::new();
    let entries = client
        .list(&target(&env, "enc"), &account(&env), "/")
        .await
        .unwrap();
    assert!(entries.iter().any(|e| e.name == "Fable of Glass (2031)"));
}

#[tokio::test]
async fn shares_exclude_admin() {
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
    let env = env_or_skip!();
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
