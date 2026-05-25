use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use std::collections::HashMap;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{ConfigSource, SettingRow};

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

fn resolve_value(desc: &SettingDescriptor, db: &HashMap<String, String>) -> (String, ConfigSource) {
    let env_value = desc.env.and_then(|name| std::env::var(name).ok());
    let db_value = db.get(desc.key).cloned();

    if desc.key == "crash_reporting.enabled" {
        if let Some(v) = db_value {
            return (v, ConfigSource::Database);
        }
        if let Some(v) = env_value {
            return (v, ConfigSource::Env);
        }
        return (desc.default.to_owned(), ConfigSource::Default);
    }

    if let Some(v) = env_value {
        return (v, ConfigSource::Env);
    }
    if let Some(v) = db_value {
        return (v, ConfigSource::Database);
    }
    (desc.default.to_owned(), ConfigSource::Default)
}

fn build_row(desc: &SettingDescriptor, db: &HashMap<String, String>) -> SettingRow {
    let (value, source) = resolve_value(desc, db);
    SettingRow {
        key: desc.key.to_owned(),
        category: desc.category.to_owned(),
        label: desc.label.to_owned(),
        kind: desc.kind.to_owned(),
        value,
        source,
        description: desc.description.map(str::to_owned),
        placeholder: desc.placeholder.map(str::to_owned),
    }
}

#[derive(Default)]
pub struct SettingsQueries;

#[Object]
impl SettingsQueries {
    async fn settings(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<SettingRow>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let db_rows = mydia_rs_entities::config_settings::Entity::find()
            .all(&state.db)
            .await?;
        let db_map: HashMap<String, String> = db_rows
            .into_iter()
            .map(|r| (r.key, r.value.unwrap_or_default()))
            .collect();

        Ok(DESCRIPTORS
            .iter()
            .map(|desc| build_row(desc, &db_map))
            .collect())
    }
}
