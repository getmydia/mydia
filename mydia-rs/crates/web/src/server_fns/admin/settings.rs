//! App-wide settings server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminSettingsLive.Index`. The
//! Phoenix page exposes a multi-section form keyed on
//! `(category, key)` pairs, reading the effective value from a
//! layered store: hard-coded defaults < `MYDIA_*` env vars <
//! `config_settings` table. Each row carries a `source` flag so
//! the UI surfaces which layer won.
//!
//! mydia-rs ships the same layering. Reads merge the rows we know
//! how to surface (the keys the Phoenix UI exposes, not the entire
//! schema — operators don't tune every leaf via the web form);
//! writes upsert into `config_settings`. Env vars are never written
//! by the UI; the operator must set them in their compose file or
//! whatever process supervisor they run.
//!
//! Validation:
//!
//! - `value` must round-trip into the declared `kind`.
//! - `kind` must be one of `string` / `integer` / `boolean`.
//! - Boolean parsing accepts the Phoenix vocab (`true` / `1` /
//!   `yes` / `on`).

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// A single config row as the page renders it. The `source` flag
/// is computed server-side so the page renders the right pill
/// without re-deriving the layering on every paint.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfigSettingRow {
    pub key: String,
    pub category: String,
    pub label: String,
    /// `string` / `integer` / `boolean`.
    pub kind: String,
    pub value: String,
    /// `default` / `env` / `database`.
    pub source: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub placeholder: Option<String>,
}

/// Wire payload for a single-setting update.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateSetting {
    pub key: String,
    pub category: String,
    pub value: String,
}

/// Snapshot of every setting the UI displays, grouped by category.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SettingsSnapshot {
    pub categories: Vec<SettingsCategory>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SettingsCategory {
    pub name: String,
    pub rows: Vec<ConfigSettingRow>,
}

#[get("/api/admin/settings")]
pub async fn list_settings() -> Result<SettingsSnapshot, ServerFnError> {
    server::list().await
}

#[post("/api/admin/settings")]
pub async fn update_setting(payload: UpdateSetting) -> Result<ConfigSettingRow, ServerFnError> {
    server::update(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{ConfigSettingRow, SettingsCategory, SettingsSnapshot, UpdateSetting};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::Db;
    use std::collections::HashMap;

    /// Descriptor for one configurable setting. Mirrors the
    /// per-key metadata the Phoenix `get_all_settings_with_sources`
    /// helper emits — label, kind, default, env variable, category.
    struct SettingDescriptor {
        key: &'static str,
        category: &'static str,
        label: &'static str,
        kind: &'static str,
        env: Option<&'static str>,
        default: &'static str,
        description: Option<&'static str>,
        placeholder: Option<&'static str>,
    }

    /// The keys the admin UI exposes. Anything not listed here is
    /// either auto-derived (the database section in the Phoenix UI
    /// is read-only, surfaced through the system page) or only
    /// settable via the toml file at boot.
    ///
    /// Adding a new key here lights it up in the UI; nothing else
    /// needs to change.
    const DESCRIPTORS: &[SettingDescriptor] = &[
        SettingDescriptor {
            key: "server.port",
            category: "Server",
            label: "HTTP port",
            kind: "integer",
            env: Some("MYDIA_SERVER__PORT"),
            default: "4000",
            description: Some("TCP port the web server listens on."),
            placeholder: None,
        },
        SettingDescriptor {
            key: "server.url_scheme",
            category: "Server",
            label: "URL scheme",
            kind: "string",
            env: Some("MYDIA_SERVER__URL_SCHEME"),
            default: "http",
            description: Some("Public scheme (used in OIDC redirects + cookie scope)."),
            placeholder: Some("https"),
        },
        SettingDescriptor {
            key: "server.url_host",
            category: "Server",
            label: "URL host",
            kind: "string",
            env: Some("MYDIA_SERVER__URL_HOST"),
            default: "localhost",
            description: Some("Public host name (no port). Used to build absolute URLs."),
            placeholder: Some("mydia.example.com"),
        },
        SettingDescriptor {
            key: "media.scan_interval_hours",
            category: "Media",
            label: "Scan interval (hours)",
            kind: "integer",
            env: Some("MYDIA_MEDIA__SCAN_INTERVAL_HOURS"),
            default: "6",
            description: Some("How often the library scanner re-walks watched paths."),
            placeholder: None,
        },
        SettingDescriptor {
            key: "metadata.language",
            category: "Metadata",
            label: "Language",
            kind: "string",
            env: Some("METADATA_LANGUAGE"),
            default: "en-US",
            description: Some(
                "Locale sent to TMDB/TVDB through the metadata relay (ISO 639-1 / BCP 47).",
            ),
            placeholder: Some("en-US"),
        },
        SettingDescriptor {
            key: "auth.local_enabled",
            category: "Authentication",
            label: "Local password auth enabled",
            kind: "boolean",
            env: Some("MYDIA_AUTH__LOCAL_ENABLED"),
            default: "true",
            description: None,
            placeholder: None,
        },
        SettingDescriptor {
            key: "auth.oidc_enabled",
            category: "Authentication",
            label: "OIDC enabled",
            kind: "boolean",
            env: Some("MYDIA_AUTH__OIDC_ENABLED"),
            default: "false",
            description: Some(
                "If on, the login page surfaces the OIDC button. Requires client id + secret.",
            ),
            placeholder: None,
        },
        SettingDescriptor {
            key: "downloads.monitor_interval_minutes",
            category: "Downloads",
            label: "Monitor interval (minutes)",
            kind: "integer",
            env: Some("MYDIA_DOWNLOADS__MONITOR_INTERVAL_MINUTES"),
            default: "5",
            description: Some("How often the download monitor polls active clients."),
            placeholder: None,
        },
        SettingDescriptor {
            key: "library.auto_repair_enabled",
            category: "Library",
            label: "Auto-repair on startup",
            kind: "boolean",
            env: Some("DATABASE_AUTO_REPAIR"),
            default: "true",
            description: Some("Queue a library re-scan on boot when orphaned files are detected."),
            placeholder: None,
        },
        SettingDescriptor {
            key: "library.auto_repair_threshold",
            category: "Library",
            label: "Auto-repair threshold",
            kind: "integer",
            env: Some("DATABASE_AUTO_REPAIR_THRESHOLD"),
            default: "10",
            description: Some("Minimum issue count required to trigger auto-repair."),
            placeholder: None,
        },
        SettingDescriptor {
            key: "crash_reporting.enabled",
            category: "Crash Reporting",
            label: "Share crashes with developers",
            kind: "boolean",
            env: Some("CRASH_REPORTING_ENABLED"),
            default: "false",
            description: Some(
                "Send anonymized crash reports through the metadata relay. UI wins over env.",
            ),
            placeholder: None,
        },
        SettingDescriptor {
            key: "feedback.enabled",
            category: "Feedback",
            label: "Show feedback button",
            kind: "boolean",
            env: None,
            default: "true",
            description: None,
            placeholder: None,
        },
        SettingDescriptor {
            key: "flaresolverr.enabled",
            category: "FlareSolverr",
            label: "Enabled",
            kind: "boolean",
            env: Some("FLARESOLVERR_ENABLED"),
            default: "false",
            description: None,
            placeholder: None,
        },
        SettingDescriptor {
            key: "flaresolverr.url",
            category: "FlareSolverr",
            label: "URL",
            kind: "string",
            env: Some("FLARESOLVERR_URL"),
            default: "",
            description: None,
            placeholder: Some("http://flaresolverr:8191"),
        },
        SettingDescriptor {
            key: "flaresolverr.timeout",
            category: "FlareSolverr",
            label: "Timeout (ms)",
            kind: "integer",
            env: Some("FLARESOLVERR_TIMEOUT"),
            default: "60000",
            description: None,
            placeholder: None,
        },
    ];

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    pub(super) async fn list() -> Result<SettingsSnapshot, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let db_rows = read_db_settings(&st.db).await?;
        let db_map: HashMap<String, String> = db_rows.into_iter().collect();

        let mut by_cat: Vec<(String, Vec<ConfigSettingRow>)> = Vec::new();
        for desc in DESCRIPTORS {
            let row = build_row(desc, &db_map);
            if let Some(slot) = by_cat.iter_mut().find(|(name, _)| name == desc.category) {
                slot.1.push(row);
            } else {
                by_cat.push((desc.category.to_owned(), vec![row]));
            }
        }

        Ok(SettingsSnapshot {
            categories: by_cat
                .into_iter()
                .map(|(name, rows)| SettingsCategory { name, rows })
                .collect(),
        })
    }

    pub(super) async fn update(payload: UpdateSetting) -> Result<ConfigSettingRow, ServerFnError> {
        let user = require_admin_user_id().await?;
        let desc = DESCRIPTORS
            .iter()
            .find(|d| d.key == payload.key)
            .ok_or_else(|| ServerFnError::new(format!("unknown setting key {:?}", payload.key)))?;
        validate_value(desc.kind, &payload.value)?;

        let st = state().await?;
        upsert_setting(
            &st.db,
            &payload.key,
            &payload.category,
            &payload.value,
            &user,
        )
        .await?;

        let db_rows = read_db_settings(&st.db).await?;
        let db_map: HashMap<String, String> = db_rows.into_iter().collect();
        Ok(build_row(desc, &db_map))
    }

    fn build_row(desc: &SettingDescriptor, db: &HashMap<String, String>) -> ConfigSettingRow {
        let (value, source) = resolve_value(desc, db);
        ConfigSettingRow {
            key: desc.key.to_owned(),
            category: desc.category.to_owned(),
            label: desc.label.to_owned(),
            kind: desc.kind.to_owned(),
            value,
            source: source.to_owned(),
            description: desc.description.map(str::to_owned),
            placeholder: desc.placeholder.map(str::to_owned),
        }
    }

    /// Resolve the effective value + source. Phoenix order:
    /// env > database > default, except for `crash_reporting.enabled`
    /// where the UI/DB wins. We mirror that quirk here.
    fn resolve_value(
        desc: &SettingDescriptor,
        db: &HashMap<String, String>,
    ) -> (String, &'static str) {
        let env_value = desc.env.and_then(|name| std::env::var(name).ok());
        let db_value = db.get(desc.key).cloned();

        if desc.key == "crash_reporting.enabled" {
            if let Some(v) = db_value {
                return (v, "database");
            }
            if let Some(v) = env_value {
                return (v, "env");
            }
            return (desc.default.to_owned(), "default");
        }

        if let Some(v) = env_value {
            return (v, "env");
        }
        if let Some(v) = db_value {
            return (v, "database");
        }
        (desc.default.to_owned(), "default")
    }

    fn validate_value(kind: &str, value: &str) -> Result<(), ServerFnError> {
        match kind {
            "string" => Ok(()),
            "integer" => {
                value.trim().parse::<i64>().map(|_| ()).map_err(|_| {
                    ServerFnError::new(format!("value {value:?} is not a valid integer"))
                })
            }
            "boolean" => match value.trim().to_ascii_lowercase().as_str() {
                "true" | "false" | "1" | "0" | "yes" | "no" | "on" | "off" => Ok(()),
                _ => Err(ServerFnError::new(format!(
                    "value {value:?} is not a valid boolean"
                ))),
            },
            other => Err(ServerFnError::new(format!("unsupported kind {other:?}"))),
        }
    }

    async fn read_db_settings(db: &Db) -> Result<Vec<(String, String)>, ServerFnError> {
        let rows: Vec<(String, String)> = match db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT key, value FROM config_settings")
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("read settings: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as("SELECT key, value FROM config_settings")
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("read settings: {err}")))?,
        };
        Ok(rows)
    }

    async fn upsert_setting(
        db: &Db,
        key: &str,
        category: &str,
        value: &str,
        user_id: &str,
    ) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        match db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?) \
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value, \
                     category = excluded.category, updated_by_id = excluded.updated_by_id, \
                     updated_at = excluded.updated_at",
                )
                .bind(key)
                .bind(value)
                .bind(category)
                .bind(user_id)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("upsert setting: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6) \
                     ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value, \
                     category = EXCLUDED.category, updated_by_id = EXCLUDED.updated_by_id, \
                     updated_at = EXCLUDED.updated_at",
                )
                .bind(key)
                .bind(value)
                .bind(category)
                .bind(user_id)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("upsert setting: {err}")))?;
            }
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn validate_value_accepts_typed_inputs() {
            assert!(validate_value("integer", "42").is_ok());
            assert!(validate_value("integer", "not a number").is_err());
            assert!(validate_value("boolean", "true").is_ok());
            assert!(validate_value("boolean", "off").is_ok());
            assert!(validate_value("boolean", "maybe").is_err());
            assert!(validate_value("string", "anything").is_ok());
            assert!(validate_value("mystery", "").is_err());
        }

        #[test]
        fn resolve_prefers_env_over_db_over_default() {
            let desc = &DESCRIPTORS[0];
            let db: HashMap<String, String> =
                std::iter::once((desc.key.to_owned(), "5555".to_owned())).collect();
            // env unset → db wins
            let (value, source) = resolve_value(desc, &db);
            assert_eq!(value, "5555");
            assert_eq!(source, "database");

            let empty: HashMap<String, String> = HashMap::new();
            let (value, source) = resolve_value(desc, &empty);
            assert_eq!(value, desc.default);
            assert_eq!(source, "default");
        }

        #[test]
        fn crash_reporting_inverts_precedence() {
            let desc = DESCRIPTORS
                .iter()
                .find(|d| d.key == "crash_reporting.enabled")
                .expect("crash reporting present");
            let db: HashMap<String, String> =
                std::iter::once((desc.key.to_owned(), "true".to_owned())).collect();
            let (value, source) = resolve_value(desc, &db);
            assert_eq!(value, "true");
            assert_eq!(
                source, "database",
                "DB wins over env for crash_reporting per Phoenix quirk"
            );
        }
    }
}
