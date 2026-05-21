//! Configuration layer for mydia-rs.
//!
//! Load order, lowest to highest precedence:
//!
//! 1. Built-in defaults (`Config::default()` and friends in [`schema`]).
//! 2. A TOML file (typically `mydia.toml`), if a path is provided.
//! 3. `MYDIA_*` environment variables (double-underscore for nesting, e.g.
//!    `MYDIA_DATABASE__TYPE=postgres`).
//! 4. `OIDC_*` environment variables. These mirror the read path Phoenix
//!    uses in `config/runtime.exs:466-546` so existing self-hoster compose
//!    `environment:` blocks work unchanged at cutover.
//!
//! Validation runs once at load time. Missing required fields exit
//! non-zero with a clear error before any DB connection is attempted.

pub mod schema;
pub mod tracing_setup;

use std::path::Path;

use figment::providers::{Env, Format, Serialized, Toml};
use figment::Figment;

pub use schema::*;

/// Errors surfaced from [`Config::load`] and [`Config::validate`].
///
/// The figment error is boxed because the underlying type is ~200 bytes,
/// which would otherwise bloat every `Result<Config, _>` on the stack.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("failed to parse config: {0}")]
    Parse(Box<figment::Error>),

    #[error("invalid configuration: {0}")]
    Invalid(String),
}

impl From<figment::Error> for ConfigError {
    fn from(err: figment::Error) -> Self {
        Self::Parse(Box::new(err))
    }
}

impl Config {
    /// Load configuration with default-file-env-OIDC layering.
    ///
    /// `file` is optional; when `None` only defaults plus environment
    /// variables are applied.
    pub fn load(file: Option<&Path>) -> Result<Self, ConfigError> {
        let mut figment = Figment::from(Serialized::defaults(Config::default()));

        if let Some(path) = file {
            figment = figment.merge(Toml::file(path));
        }

        // MYDIA_CONFIG and MYDIA_KEEP_ALIVE are CLI/process-level
        // controls, not config keys; ignore them so figment doesn't
        // try to slot them into the Config struct as unknown fields.
        figment = figment.merge(
            Env::prefixed("MYDIA_")
                .split("__")
                .ignore(&["CONFIG", "KEEP_ALIVE"]),
        );

        let mut config: Config = figment.extract()?;
        apply_oidc_env(&mut config);
        config.validate()?;
        Ok(config)
    }

    /// Validate the loaded configuration. Run automatically by [`Self::load`].
    pub fn validate(&self) -> Result<(), ConfigError> {
        // Auth: at least one method must be enabled. Mirrors
        // `Mydia.Config.Schema.validate_configuration/1`.
        if !self.auth.local_enabled && !self.auth.oidc_enabled {
            return Err(ConfigError::Invalid(
                "at least one authentication method (local or oidc) must be enabled".into(),
            ));
        }

        if self.auth.oidc_enabled {
            if self.auth.oidc_client_id.is_none() || self.auth.oidc_client_secret.is_none() {
                return Err(ConfigError::Invalid(
                    "oidc_enabled requires oidc_client_id and oidc_client_secret".into(),
                ));
            }
            if self.auth.oidc_issuer.is_none() && self.auth.oidc_discovery_document_uri.is_none() {
                return Err(ConfigError::Invalid(
                    "oidc_enabled requires either oidc_issuer or oidc_discovery_document_uri"
                        .into(),
                ));
            }
        }

        // Database: exactly one of url/path must be set, matching the chosen
        // driver. The full driver-presence check (which sqlx feature is
        // compiled into this binary) lands in U4 once sqlx is wired in.
        match self.database.db_type {
            DatabaseType::Sqlite => {
                if self.database.path.as_deref().unwrap_or("").is_empty() {
                    return Err(ConfigError::Invalid(
                        "database.type = sqlite requires database.path".into(),
                    ));
                }
            }
            DatabaseType::Postgres => {
                if self.database.url.as_deref().unwrap_or("").is_empty() {
                    return Err(ConfigError::Invalid(
                        "database.type = postgres requires database.url".into(),
                    ));
                }
            }
        }

        if self.database.pool_size == 0 {
            return Err(ConfigError::Invalid(
                "database.pool_size must be greater than zero".into(),
            ));
        }

        Ok(())
    }
}

/// Overlay `OIDC_*` env vars onto [`AuthConfig`]. Called by [`Config::load`].
/// Exposed for tests that want to drive the OIDC env-var contract directly.
pub fn apply_oidc_env(config: &mut Config) {
    let issuer = std::env::var("OIDC_ISSUER").ok();
    let discovery = std::env::var("OIDC_DISCOVERY_DOCUMENT_URI").ok();
    let client_id = std::env::var("OIDC_CLIENT_ID").ok();
    let client_secret = std::env::var("OIDC_CLIENT_SECRET").ok();
    let redirect_uri = std::env::var("OIDC_REDIRECT_URI").ok();
    let disable_par = std::env::var("OIDC_DISABLE_PAR").ok().and_then(parse_bool);

    let any_set = issuer.is_some()
        || discovery.is_some()
        || client_id.is_some()
        || client_secret.is_some()
        || redirect_uri.is_some()
        || disable_par.is_some();

    if !any_set {
        return;
    }

    if let Some(v) = issuer {
        config.auth.oidc_issuer = Some(v);
    }
    if let Some(v) = discovery {
        // Match Phoenix: derive issuer from discovery URI if issuer is empty.
        if config.auth.oidc_issuer.is_none() {
            let derived = v
                .trim_end_matches("/.well-known/openid-configuration")
                .to_string();
            if !derived.is_empty() {
                config.auth.oidc_issuer = Some(derived);
            }
        }
        config.auth.oidc_discovery_document_uri = Some(v);
    }
    if let Some(v) = client_id {
        config.auth.oidc_client_id = Some(v);
    }
    if let Some(v) = client_secret {
        config.auth.oidc_client_secret = Some(v);
    }
    if let Some(v) = redirect_uri {
        config.auth.oidc_redirect_uri = Some(v);
    }
    if let Some(v) = disable_par {
        config.auth.oidc_disable_par = v;
    }

    // OIDC env vars are the operator's explicit "I want OIDC" signal even
    // if the TOML file didn't set oidc_enabled. Phoenix derives the same
    // implicit enable in `runtime.exs:488`.
    if config.auth.oidc_client_id.is_some() && config.auth.oidc_client_secret.is_some() {
        config.auth.oidc_enabled = true;
    }
}

fn parse_bool(s: String) -> Option<bool> {
    match s.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}
