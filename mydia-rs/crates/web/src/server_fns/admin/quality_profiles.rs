//! Quality-profile management.
//!
//! Phoenix counterpart: `MydiaWeb.AdminQualityProfilesLive` plus
//! `MydiaWeb.AdminQualityProfileFormLive`. The Phoenix surface is
//! the most complex of the admin pages — a profile contains an
//! ordered list of quality-cutoff items, each with its own
//! resolution/codec/source enums and a `cutoff` flag marking the
//! upgrade target. That nested-form pattern doesn't map cleanly
//! onto the [`crate::components::admin::config_form`] primitive
//! today.
//!
//! U28 follow-up ships the list-view read path so the page mounts
//! and reflects whatever's already in the database (seeded from
//! defaults at install time, or edited via SQL/CLI as a stop-gap).
//! CRUD with nested cutoff items is a follow-up; the placeholder
//! page surfaces that explicitly so admins know where they stand.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QualityProfileRow {
    pub id: String,
    pub name: String,
    /// Total count of cutoff items configured on this profile.
    /// Sourced via a `JOIN` so the list view shows the shape without
    /// preloading the nested rows.
    pub cutoff_count: i64,
    pub inserted_at: Option<String>,
}

#[get("/api/admin/quality_profiles")]
pub async fn list_quality_profiles() -> Result<Vec<QualityProfileRow>, ServerFnError> {
    server::list().await
}

#[cfg(feature = "server")]
mod server {
    use super::QualityProfileRow;
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::Db;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    type Row = (String, String, i64, Option<chrono::DateTime<chrono::Utc>>);

    pub(super) async fn list() -> Result<Vec<QualityProfileRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT p.id, p.name, \
                        (SELECT COUNT(*) FROM quality_profile_cutoffs c WHERE c.quality_profile_id = p.id), \
                        p.inserted_at \
                 FROM quality_profiles p ORDER BY p.inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query quality_profiles: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT p.id, p.name, \
                        (SELECT COUNT(*) FROM quality_profile_cutoffs c WHERE c.quality_profile_id = p.id), \
                        p.inserted_at \
                 FROM quality_profiles p ORDER BY p.inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query quality_profiles: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(|(id, name, cutoff_count, inserted_at)| QualityProfileRow {
                id,
                name,
                cutoff_count,
                inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
            })
            .collect())
    }
}
