//! Integration tests for the config loader.
//!
//! These tests mutate process-global state (env vars) and the figment
//! load path. They must run single-threaded to stay deterministic; we
//! get that by living in a single integration-test binary and serializing
//! env mutation through a module-local mutex.

use std::path::Path;
use std::sync::{Mutex, MutexGuard, OnceLock};

use mydia_rs_config::{
    apply_oidc_env, AuthConfig, Config, ConfigError, DatabaseType, LogLevel,
};
use tempfile::NamedTempFile;

fn env_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    // Poisoning is irrelevant for these tests; recover and continue.
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

const OIDC_ENV_KEYS: &[&str] = &[
    "OIDC_ISSUER",
    "OIDC_DISCOVERY_DOCUMENT_URI",
    "OIDC_CLIENT_ID",
    "OIDC_CLIENT_SECRET",
    "OIDC_REDIRECT_URI",
    "OIDC_DISABLE_PAR",
];

const MYDIA_ENV_KEYS: &[&str] = &[
    "MYDIA_DATABASE__TYPE",
    "MYDIA_DATABASE__URL",
    "MYDIA_DATABASE__PATH",
    "MYDIA_DATABASE__POOL_SIZE",
    "MYDIA_LOGGING__LEVEL",
    "MYDIA_SERVER__PORT",
    "MYDIA_CONFIG",
    "MYDIA_KEEP_ALIVE",
];

fn clear_env() {
    for key in OIDC_ENV_KEYS.iter().chain(MYDIA_ENV_KEYS.iter()) {
        // SAFETY: env mutation is serialized by env_lock(); these tests
        // are single-threaded with respect to each other.
        unsafe { std::env::remove_var(key) };
    }
}

fn write_toml(contents: &str) -> NamedTempFile {
    let file = NamedTempFile::new().expect("tempfile");
    std::fs::write(file.path(), contents).expect("write toml");
    file
}

fn load_from_path(path: &Path) -> Result<Config, ConfigError> {
    Config::load(Some(path))
}

#[test]
fn defaults_alone_pass_validation() {
    let _guard = env_lock();
    clear_env();
    let cfg = Config::load(None).expect("defaults must validate");
    assert_eq!(cfg.database.db_type, DatabaseType::Sqlite);
    assert_eq!(cfg.database.path.as_deref(), Some("mydia_dev.db"));
    assert!(cfg.auth.local_enabled);
    assert!(!cfg.auth.oidc_enabled);
    assert_eq!(cfg.logging.level, LogLevel::Info);
}

#[test]
fn toml_file_overrides_defaults() {
    let _guard = env_lock();
    clear_env();
    let file = write_toml(
        r#"
        [server]
        port = 4321
        host = "127.0.0.1"
        url_scheme = "https"
        url_host = "media.example.com"
        allowed_origins = []

        [database]
        type = "postgres"
        url = "postgres://mydia:secret@db/mydia"
        pool_size = 10
        timeout_ms = 60000
        busy_timeout_ms = 30000
        journal_mode = "wal"
        synchronous = "normal"
        cache_size_kib = -64000

        [logging]
        level = "debug"
        format = "json"
        "#,
    );

    let cfg = load_from_path(file.path()).expect("toml load");
    assert_eq!(cfg.server.port, 4321);
    assert_eq!(cfg.database.db_type, DatabaseType::Postgres);
    assert_eq!(
        cfg.database.url.as_deref(),
        Some("postgres://mydia:secret@db/mydia")
    );
    assert_eq!(cfg.logging.level, LogLevel::Debug);
}

#[test]
fn mydia_env_overrides_toml() {
    let _guard = env_lock();
    clear_env();
    let file = write_toml(
        r#"
        [database]
        type = "sqlite"
        path = "ignored.db"
        "#,
    );
    unsafe {
        std::env::set_var("MYDIA_DATABASE__PATH", "/var/lib/mydia/from-env.db");
    }
    let cfg = load_from_path(file.path()).expect("load");
    assert_eq!(
        cfg.database.path.as_deref(),
        Some("/var/lib/mydia/from-env.db")
    );
}

#[test]
fn missing_required_database_fields_error() {
    let _guard = env_lock();
    clear_env();
    let file = write_toml(
        r#"
        [database]
        type = "postgres"
        # url intentionally omitted
        "#,
    );
    let err = load_from_path(file.path()).expect_err("must reject");
    assert!(format!("{err}").contains("postgres requires database.url"));
}

#[test]
fn invalid_log_level_rejected_at_parse_time() {
    let _guard = env_lock();
    clear_env();
    let file = write_toml(
        r#"
        [logging]
        level = "shout"
        "#,
    );
    let err = load_from_path(file.path()).expect_err("must reject");
    assert!(matches!(err, ConfigError::Parse(_)));
}

#[test]
fn at_least_one_auth_method_required() {
    let _guard = env_lock();
    clear_env();
    let file = write_toml(
        r#"
        [auth]
        local_enabled = false
        oidc_enabled = false
        "#,
    );
    let err = load_from_path(file.path()).expect_err("must reject");
    assert!(format!("{err}").contains("at least one authentication method"));
}

#[test]
fn oidc_env_vars_overlay_implicitly_enable_oidc() {
    let _guard = env_lock();
    clear_env();
    unsafe {
        std::env::set_var("OIDC_ISSUER", "https://auth.example.com");
        std::env::set_var("OIDC_CLIENT_ID", "mydia-client");
        std::env::set_var("OIDC_CLIENT_SECRET", "supersecret");
        std::env::set_var("OIDC_REDIRECT_URI", "https://m.example.com/auth/oidc/callback");
    }

    let cfg = Config::load(None).expect("oidc env load");
    assert!(cfg.auth.oidc_enabled);
    assert_eq!(cfg.auth.oidc_issuer.as_deref(), Some("https://auth.example.com"));
    assert_eq!(cfg.auth.oidc_client_id.as_deref(), Some("mydia-client"));
    assert_eq!(
        cfg.auth.oidc_redirect_uri.as_deref(),
        Some("https://m.example.com/auth/oidc/callback")
    );
}

#[test]
fn oidc_discovery_uri_derives_issuer_when_empty() {
    let _guard = env_lock();
    clear_env();

    let mut cfg = Config {
        auth: AuthConfig {
            oidc_issuer: None,
            ..AuthConfig::default()
        },
        ..Config::default()
    };

    unsafe {
        std::env::set_var(
            "OIDC_DISCOVERY_DOCUMENT_URI",
            "https://auth.example.com/.well-known/openid-configuration",
        );
        std::env::set_var("OIDC_CLIENT_ID", "mydia-client");
        std::env::set_var("OIDC_CLIENT_SECRET", "supersecret");
    }

    apply_oidc_env(&mut cfg);
    assert_eq!(cfg.auth.oidc_issuer.as_deref(), Some("https://auth.example.com"));
    assert!(cfg.auth.oidc_enabled);
}

#[test]
fn process_level_env_vars_dont_pollute_config() {
    // Regression: MYDIA_CONFIG and MYDIA_KEEP_ALIVE are clap-level
    // CLI overrides, not Config fields. figment would reject them as
    // unknown top-level keys if we let its MYDIA_-prefix scan see
    // them. The loader explicitly ignores those two names.
    let _guard = env_lock();
    clear_env();
    unsafe {
        std::env::set_var("MYDIA_CONFIG", "/etc/mydia/mydia.toml");
        std::env::set_var("MYDIA_KEEP_ALIVE", "true");
    }
    Config::load(None).expect("must load despite process-level env vars");
}

#[test]
fn empty_library_paths_is_allowed() {
    let _guard = env_lock();
    clear_env();
    let cfg = Config::load(None).expect("load");
    assert!(cfg.library.paths.is_empty());
}
