use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use sea_orm::{ConnectionTrait, DatabaseBackend, Statement};
use std::sync::OnceLock;
use std::time::Instant;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{SetupCounts, SystemStatus};

static BOOT: OnceLock<Instant> = OnceLock::new();

#[derive(Default)]
pub struct SystemQueries;

#[Object]
impl SystemQueries {
    async fn system_status(&self, ctx: &Context<'_>) -> async_graphql::Result<SystemStatus> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let boot = *BOOT.get_or_init(Instant::now);
        let uptime = format_uptime(boot.elapsed());

        let (adapter, location) = describe_db(&state.db);
        let (size, health) = match probe_db(&state.db).await {
            Ok(ok) => ok,
            Err(_) => ("unknown".to_owned(), "unhealthy".to_owned()),
        };

        let library_paths_count = mydia_rs_entities::library_paths::Entity::find()
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let download_clients_count = mydia_rs_entities::download_client_configs::Entity::find()
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let indexers_count = mydia_rs_entities::indexer_configs::Entity::find()
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let active_transcodes = mydia_rs_entities::transcode_jobs::Entity::find()
            .filter(mydia_rs_entities::transcode_jobs::Column::Status.is_in([
                "pending",
                "transcoding",
                "playing",
            ]))
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let active_streaming_sessions = 0i32;

        let user_count = mydia_rs_entities::users::Entity::find()
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let media_count = mydia_rs_entities::media_items::Entity::find()
            .count(&state.db)
            .await
            .map(|n| i32::try_from(n).unwrap_or(i32::MAX))
            .unwrap_or(0);
        let path_count = library_paths_count;

        Ok(SystemStatus {
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            build_target: std::env::consts::OS.to_owned(),
            database_adapter: adapter.to_owned(),
            database_health: health,
            database_size: size,
            database_location: location,
            uptime,
            library_paths_count,
            download_clients_count,
            indexers_count,
            active_transcodes,
            active_streaming_sessions,
            setup_counts: SetupCounts {
                user_count,
                media_count,
                library_path_count: path_count,
            },
        })
    }
}

fn describe_db(db: &mydia_rs_db::DatabaseConnection) -> (&'static str, String) {
    match db.get_database_backend() {
        DatabaseBackend::Sqlite => ("sqlite", "(configured)".to_owned()),
        DatabaseBackend::Postgres => ("postgres", "(configured)".to_owned()),
        _ => ("unknown", "(configured)".to_owned()),
    }
}

async fn probe_db(
    db: &mydia_rs_db::DatabaseConnection,
) -> Result<(String, String), sea_orm::DbErr> {
    let backend = db.get_database_backend();
    let sql = match backend {
        DatabaseBackend::Sqlite => {
            "SELECT page_count * page_size AS s FROM pragma_page_count(), pragma_page_size()"
        }
        DatabaseBackend::Postgres => "SELECT pg_database_size(current_database())::bigint AS s",
        _ => return Ok(("unknown".to_owned(), "unhealthy".to_owned())),
    };
    let row = db
        .query_one_raw(Statement::from_string(backend, sql.to_owned()))
        .await?;
    let size_bytes = match row {
        Some(r) => r.try_get::<i64>("", "s")?,
        None => 0,
    };
    Ok((format_bytes(size_bytes), "healthy".to_owned()))
}

fn format_bytes(bytes: i64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let b = bytes as f64;
    if b >= GB {
        format!("{:.2} GB", b / GB)
    } else if b >= MB {
        format!("{:.2} MB", b / MB)
    } else if b >= KB {
        format!("{:.2} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

fn format_uptime(elapsed: std::time::Duration) -> String {
    let seconds = elapsed.as_secs();
    let minutes = seconds / 60;
    let hours = minutes / 60;
    let days = hours / 24;
    if days > 0 {
        format!("{days}d {}h", hours % 24)
    } else if hours > 0 {
        format!("{hours}h {}m", minutes % 60)
    } else if minutes > 0 {
        format!("{minutes}m {}s", seconds % 60)
    } else {
        format!("{seconds}s")
    }
}
