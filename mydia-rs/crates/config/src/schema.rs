//! Configuration schema mirroring the boot-essential subset of
//! `Mydia.Config.Schema`. Fields the Phoenix schema treats as DB-driven
//! (`download_clients`, indexers, `media_servers`) live in the database at
//! runtime and are intentionally not mirrored here.

use serde::{Deserialize, Serialize};

/// Top-level configuration loaded at boot.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub server: ServerConfig,
    pub database: DatabaseConfig,
    pub auth: AuthConfig,
    pub metadata: MetadataConfig,
    pub logging: LoggingConfig,
    pub p2p: P2pConfig,
    pub library: LibraryConfig,
    pub hls: HlsConfig,
    pub features: FeaturesConfig,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServerConfig {
    pub port: u16,
    pub host: String,
    pub url_scheme: UrlScheme,
    pub url_host: String,
    /// HTTP origins allowed for WebSocket and CORS. Matches Phoenix's
    /// `PHX_CHECK_ORIGIN` semantics: empty list means "allow only the
    /// configured `url_host`".
    pub allowed_origins: Vec<String>,
    /// Used to sign session cookies and the Guardian-compatible media-token
    /// JWTs. Required for any non-trivial boot; omitted in tests where the
    /// auth surface is not exercised.
    pub secret_key_base: Option<String>,
    /// Shared between Phoenix and mydia-rs so JWT media tokens issued by
    /// either backend verify against the other during the parallel window.
    pub guardian_secret_key: Option<String>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            port: 4001,
            host: "0.0.0.0".into(),
            url_scheme: UrlScheme::Http,
            url_host: "localhost".into(),
            allowed_origins: Vec::new(),
            secret_key_base: None,
            guardian_secret_key: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UrlScheme {
    Http,
    Https,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DatabaseConfig {
    /// Selects the runtime driver. The driver-presence check at startup
    /// (see `Config::validate`) rejects values whose sqlx feature is not
    /// compiled into this binary, replacing Phoenix's compile-time guard
    /// at `config/runtime.exs:30-54`.
    #[serde(rename = "type")]
    pub db_type: DatabaseType,
    /// Connection URL when `db_type = postgres`; ignored for sqlite.
    pub url: Option<String>,
    /// Filesystem path when `db_type = sqlite`; ignored for postgres.
    pub path: Option<String>,
    pub pool_size: u32,
    pub timeout_ms: u32,
    pub busy_timeout_ms: u32,
    /// SQLite-only knobs; ignored when `db_type = postgres`.
    pub journal_mode: SqliteJournalMode,
    pub synchronous: SqliteSynchronous,
    /// Negative values are `SQLite`'s "kibibytes of cache" convention
    /// (e.g. `-64000` -> 64 MiB). Default mirrors Phoenix.
    pub cache_size_kib: i64,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        Self {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some("mydia_dev.db".into()),
            pool_size: 5,
            timeout_ms: 60_000,
            busy_timeout_ms: 30_000,
            journal_mode: SqliteJournalMode::Wal,
            synchronous: SqliteSynchronous::Normal,
            cache_size_kib: -64_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DatabaseType {
    Sqlite,
    Postgres,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SqliteJournalMode {
    Delete,
    Truncate,
    Persist,
    Memory,
    Wal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SqliteSynchronous {
    Off,
    Normal,
    Full,
    Extra,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthConfig {
    pub local_enabled: bool,
    pub oidc_enabled: bool,
    pub oidc_issuer: Option<String>,
    pub oidc_discovery_document_uri: Option<String>,
    pub oidc_client_id: Option<String>,
    pub oidc_client_secret: Option<String>,
    pub oidc_redirect_uri: Option<String>,
    pub oidc_scopes: String,
    /// Force plain query-param authorize (skip PAR/JAR even when the
    /// discovery doc advertises support). Required workaround for some
    /// Authelia 4.39+ deployments; mirrors the Phoenix-side quirk toggle
    /// at `config/dev.exs:341-360`.
    pub oidc_disable_par: bool,
    pub jwt_ttl_days: u32,
    pub jwt_allowed_drift_ms: u32,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            local_enabled: true,
            oidc_enabled: false,
            oidc_issuer: None,
            oidc_discovery_document_uri: None,
            oidc_client_id: None,
            oidc_client_secret: None,
            oidc_redirect_uri: None,
            oidc_scopes: "openid profile email".into(),
            oidc_disable_par: false,
            jwt_ttl_days: 30,
            jwt_allowed_drift_ms: 2_000,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataConfig {
    pub relay_url: String,
    /// ISO 639-1 ("de") or BCP 47 ("de-DE") sent to TMDB/TVDB via the relay.
    pub language: String,
}

impl Default for MetadataConfig {
    fn default() -> Self {
        Self {
            relay_url: "https://relay.mydia.dev".into(),
            language: "en-US".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoggingConfig {
    pub level: LogLevel,
    pub format: LogFormat,
}

impl Default for LoggingConfig {
    fn default() -> Self {
        Self {
            level: LogLevel::Info,
            format: LogFormat::Text,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Debug,
    Info,
    Warning,
    Error,
}

impl LogLevel {
    pub fn as_tracing_filter(self) -> &'static str {
        match self {
            Self::Debug => "debug",
            Self::Info => "info",
            // tracing uses "warn"; we accept "warning" in config for parity
            // with Phoenix's Logger config but normalize on the way out.
            Self::Warning => "warn",
            Self::Error => "error",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogFormat {
    /// Human-friendly, default in development.
    Text,
    /// Structured single-line JSON, default in production.
    Json,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct P2pConfig {
    pub enabled: bool,
    /// Path to the persistent keypair file. The p2p Host refuses to start
    /// without it (mirrors Phoenix).
    pub keypair_path: Option<String>,
}

impl Default for P2pConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            keypair_path: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LibraryConfig {
    /// Filesystem paths to watch. Empty is allowed (operator with no
    /// libraries yet) and surfaces as a no-op scanner at boot.
    pub paths: Vec<String>,
    pub scan_interval_seconds: u64,
    pub monitor_by_default: bool,
}

impl Default for LibraryConfig {
    fn default() -> Self {
        Self {
            paths: Vec::new(),
            scan_interval_seconds: 3600,
            monitor_by_default: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HlsConfig {
    pub temp_dir: String,
    pub idle_timeout_seconds: u64,
    /// Boot-time cleanup removes session dirs older than this. Matches
    /// `lib/mydia/streaming/hls_cleanup.ex:16` `@stale_threshold_hours 24`.
    pub stale_threshold_hours: u64,
}

impl Default for HlsConfig {
    fn default() -> Self {
        Self {
            temp_dir: "/tmp/mydia-hls".into(),
            idle_timeout_seconds: 1800,
            stale_threshold_hours: 24,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FeaturesConfig {
    pub playback_enabled: bool,
    pub cardigann_enabled: bool,
    pub import_lists_enabled: bool,
    pub remote_access_enabled: bool,
}

impl Default for FeaturesConfig {
    fn default() -> Self {
        Self {
            playback_enabled: true,
            cardigann_enabled: false,
            import_lists_enabled: false,
            remote_access_enabled: false,
        }
    }
}
