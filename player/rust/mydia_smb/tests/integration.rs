//! Integration tests against `tests/samba/run-samba.sh`.
//! Without `MYDIA_SMB_TEST_HOST` they print "skipped" and pass.

use std::time::Duration;

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

#[tokio::test]
async fn connects_to_guest_share() {
    let Some(env) = test_env() else {
        println!("skipped");
        return;
    };
    let mut client = smb2::SmbClient::connect(smb2::ClientConfig {
        addr: format!("{}:{}", env.host, env.port),
        timeout: Duration::from_secs(10),
        ..Default::default()
    })
    .await
    .unwrap();
    let mut tree = client.connect_share("guest").await.unwrap();
    let entries = client.list_directory(&mut tree, "").await.unwrap();
    assert!(entries.iter().any(|e| e.name == "Fable of Glass (2031)"));
}
