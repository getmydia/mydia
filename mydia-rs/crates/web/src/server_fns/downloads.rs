//! Downloads queue server functions (U27).
//!
//! Phoenix counterpart: `MydiaWeb.DownloadsLive.Index`. The Phoenix
//! page is the largest U27 surface — tabs (Queue / Completed / Issues),
//! batch selection, retry/pause/resume/cancel mutations, library-search
//! integration for unmatched downloads, file-resolution forms for
//! ambiguous unpacks. The Rust port ships the read surface, the cancel
//! mutation, and the `manually_match_download` write path that pairs
//! an unmatched download with a `media_items` row by id.
//!
//! TODO(U27.downloads-followup): port `resolve_file_mappings`,
//! batch-delete, batch-retry. The Phoenix file has 900+ LOC of event
//! handlers; this slice covers the operational visibility shape plus
//! the manual-match affordance — the single most-clicked authoring
//! flow on the Phoenix page.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Page-size matching `@items_per_page` in
/// `lib/mydia_web/live/downloads_live/index.ex`.
pub const PAGE_SIZE: i64 = 50;

/// A row in the downloads queue. Mirrors the fields the Phoenix
/// template renders directly — title, status, progress, the few
/// metadata-derived bytes (size, seeders, leechers).
///
/// Migration 20251105033610 dropped the `status` and `progress`
/// columns from `downloads`; Phoenix now derives them in-memory from
/// each download-client adapter's live state. The Rust port hasn't
/// wired the adapter probes into the server-fn layer yet, so `status`
/// is populated server-side from the surviving columns (a coarse
/// "active" / "completed" / "failed" tri-state) and `progress` is
/// always `None`. The wire field names stay so the SPA components
/// don't have to flex.
///
/// TODO(U27.downloads-followup): once the adapter-probe layer lands,
/// populate `status` with the full Phoenix vocabulary (downloading /
/// seeding / checking / paused / queued / missing / unknown) and
/// populate `progress` from the client's report.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadRow {
    pub id: String,
    pub title: String,
    /// Coarse derived status, populated server-side. One of "active",
    /// "completed", "failed", or "imported".
    pub status: String,
    /// 0.0..=1.0 when the column existed. Always `None` until the
    /// adapter-probe layer is ported.
    pub progress: Option<f64>,
    pub indexer: Option<String>,
    pub download_client: Option<String>,
    pub error_message: Option<String>,
    pub inserted_at: String,
    pub completed_at: Option<String>,
    /// Title of the parent show / movie if associated.
    pub media_item_title: Option<String>,
    pub media_item_id: Option<String>,
    pub media_item_type: Option<String>,
    pub episode_season: Option<i64>,
    pub episode_number: Option<i64>,
    /// Bytes downloaded so far (when the client reports it).
    pub bytes_pulled: Option<i64>,
    pub import_failed_at: Option<String>,
    pub match_status: Option<String>,
}

/// Tab discriminator on the page — Queue (active) / Completed
/// (imported) / Issues (unmatched / unresolved / failed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DownloadsTab {
    #[default]
    Queue,
    Completed,
    Issues,
}

impl DownloadsTab {
    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s {
            "completed" => Self::Completed,
            "issues" => Self::Issues,
            _ => Self::Queue,
        }
    }

    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queue => "queue",
            Self::Completed => "completed",
            Self::Issues => "issues",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DownloadsQuery {
    pub tab: String,
    #[serde(default)]
    pub page: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadsPage {
    pub rows: Vec<DownloadRow>,
    pub has_more: bool,
}

#[get("/api/downloads")]
pub async fn list_downloads(query: DownloadsQuery) -> Result<DownloadsPage, ServerFnError> {
    server::list(query).await
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CancelDownload {
    pub id: String,
}

#[post("/api/downloads/cancel")]
pub async fn cancel_download(payload: CancelDownload) -> Result<(), ServerFnError> {
    server::cancel(payload).await
}

/// Payload for [`manually_match_download`] — wires an existing
/// `downloads` row to a `media_items` row by id, clearing the
/// `unmatched` state. Phoenix calls this from a modal that opens
/// when the operator clicks an unmatched download row.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManuallyMatchDownload {
    pub download_id: String,
    pub media_item_id: String,
}

#[post("/api/downloads/manual_match")]
pub async fn manually_match_download(payload: ManuallyMatchDownload) -> Result<(), ServerFnError> {
    server::manually_match(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{
        CancelDownload, DownloadRow, DownloadsPage, DownloadsQuery, DownloadsTab,
        ManuallyMatchDownload, PAGE_SIZE,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{downloads, episodes, media_items};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{QueryOrder, QuerySelect};
    use sea_orm::sea_query::{Condition, Expr, ExprTrait};

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list(query: DownloadsQuery) -> Result<DownloadsPage, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        let tab = DownloadsTab::parse(&query.tab);
        let page = Ord::max(query.page, 0);
        let offset = page * PAGE_SIZE;
        let limit = PAGE_SIZE + 1;

        let rows = fetch_rows(&st.db, tab, offset, limit).await?;
        let has_more = rows.len() as i64 > PAGE_SIZE;
        Ok(DownloadsPage {
            rows: rows.into_iter().take(PAGE_SIZE as usize).collect(),
            has_more,
        })
    }

    pub(super) async fn cancel(payload: CancelDownload) -> Result<(), ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        // Phoenix's `Mydia.Downloads.Queue.cancel_download/2` removes the
        // torrent from the configured client adapter and then deletes
        // the database row (see `lib/mydia/downloads/queue.ex:68-87`).
        // The adapter call isn't wired into the Rust server-fn layer
        // yet — without it, the operator's "Cancel" click would leave a
        // ghost torrent in qbittorrent / transmission / etc. We delete
        // the row anyway so the UI moves forward; the orphan torrent
        // will surface as "missing" once the probe layer lands.
        //
        // TODO(U27.downloads-followup): once the adapter probe surface
        // exists, wrap this in the full
        //   Client.remove_download(adapter, config, client_id, opts)
        //   |> History.delete_download
        // sequence so cancelling here also stops the underlying client.
        let Some(wrapper) = parse_uuid(&payload.id) else {
            return Err(ServerFnError::new(format!(
                "invalid download id {}",
                payload.id
            )));
        };
        let backend = st.db.get_database_backend();
        let res = downloads::Entity::delete_many()
            .filter(Expr::col(downloads::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("cancel download: {err}")))?;

        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download with id {}",
                payload.id
            )));
        }
        Ok(())
    }

    /// Manual-match write path. Verifies the target `media_items` row
    /// exists, then updates the download's `media_item_id` plus the
    /// `match_status` column to `matched`, clearing any prior
    /// `unmatched` state. The Phoenix flow also re-enqueues the
    /// importer for `imported_at IS NULL` rows; that piece sits in
    /// `crates/jobs/` and is intentionally not invoked here so the
    /// admin's manual-match action stays a pure database update for
    /// now. A TODO marker calls out the gap.
    pub(super) async fn manually_match(
        payload: ManuallyMatchDownload,
    ) -> Result<(), ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let now = chrono::Utc::now();

        // Guard: the media_items row must exist before we wire it in.
        let Some(media_wrapper) = parse_uuid(&payload.media_item_id) else {
            return Err(ServerFnError::new(format!(
                "invalid media_item id {}",
                payload.media_item_id
            )));
        };
        let Some(download_wrapper) = parse_uuid(&payload.download_id) else {
            return Err(ServerFnError::new(format!(
                "invalid download id {}",
                payload.download_id
            )));
        };
        let backend = st.db.get_database_backend();
        let media_present = media_items::Entity::find()
            .filter(Expr::col(media_items::Column::Id).eq(media_wrapper.into_simple_expr(backend)))
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("verify media_item: {err}")))?;
        if media_present.is_none() {
            return Err(ServerFnError::new(format!(
                "no media_item with id {}",
                payload.media_item_id
            )));
        }

        let now_secs = DateTimeSecs::from(now);
        let res = downloads::Entity::update_many()
            .col_expr(
                downloads::Column::MediaItemId,
                media_wrapper.into_simple_expr(backend),
            )
            .col_expr(
                downloads::Column::MatchStatus,
                Expr::value("matched".to_owned()),
            )
            .col_expr(
                downloads::Column::UpdatedAt,
                now_secs.into_simple_expr(backend),
            )
            .filter(Expr::col(downloads::Column::Id).eq(download_wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("manual match: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download with id {}",
                payload.download_id
            )));
        }
        // TODO(U27.downloads-followup): once `crates/jobs/` exposes a
        // re-import worker, enqueue it here so the Phoenix
        // `manually_match_download → reimport` flow runs end-to-end.
        Ok(())
    }

    async fn fetch_rows(
        db: &DatabaseConnection,
        tab: DownloadsTab,
        offset: i64,
        limit: i64,
    ) -> Result<Vec<DownloadRow>, ServerFnError> {
        // Build the WHERE clause from the tab; SeaORM `Condition`
        // composes per-tab predicates rather than the prior raw-SQL
        // CASE chain.
        let cond = match tab {
            DownloadsTab::Queue => Condition::all()
                .add(downloads::Column::ImportedAt.is_null())
                .add(downloads::Column::CompletedAt.is_null())
                .add(downloads::Column::ImportFailedAt.is_null()),
            DownloadsTab::Completed => {
                Condition::all().add(downloads::Column::ImportedAt.is_not_null())
            }
            DownloadsTab::Issues => Condition::any()
                .add(downloads::Column::ImportFailedAt.is_not_null())
                .add(
                    downloads::Column::MatchStatus
                        .is_in(["unmatched".to_owned(), "unresolved_files".to_owned()]),
                ),
        };

        let raw_rows = downloads::Entity::find()
            .filter(cond)
            .order_by_desc(downloads::Column::InsertedAt)
            .offset(u64::try_from(offset).unwrap_or(0))
            .limit(u64::try_from(limit).unwrap_or(50))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list downloads: {err}")))?;

        // Hydrate parents in two side-band fetches to keep the SeaORM
        // surface vanilla — find_with_related would require explicit
        // join wiring for the optional FKs.
        let media_ids: Vec<UuidText> = raw_rows.iter().filter_map(|r| r.media_item_id).collect();
        let media_map: std::collections::HashMap<UuidText, media_items::Model> =
            if media_ids.is_empty() {
                std::collections::HashMap::new()
            } else {
                media_items::Entity::find()
                    .filter(media_items::Column::Id.is_in(media_ids))
                    .all(db)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list downloads media: {err}")))?
                    .into_iter()
                    .map(|m| (m.id, m))
                    .collect()
            };
        let episode_ids: Vec<UuidText> = raw_rows.iter().filter_map(|r| r.episode_id).collect();
        let episode_map: std::collections::HashMap<UuidText, episodes::Model> =
            if episode_ids.is_empty() {
                std::collections::HashMap::new()
            } else {
                episodes::Entity::find()
                    .filter(episodes::Column::Id.is_in(episode_ids))
                    .all(db)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list downloads episodes: {err}")))?
                    .into_iter()
                    .map(|m| (m.id, m))
                    .collect()
            };

        Ok(raw_rows
            .into_iter()
            .map(|d| {
                let m = d.media_item_id.and_then(|id| media_map.get(&id));
                let e = d.episode_id.and_then(|id| episode_map.get(&id));
                let status = derive_status(
                    d.completed_at.as_ref().map(|dt| &dt.0),
                    d.imported_at.as_ref().map(|dt| &dt.0),
                    d.import_failed_at.as_ref().map(|dt| &dt.0),
                );
                DownloadRow {
                    id: d.id.to_string(),
                    title: d.title,
                    status: status.to_owned(),
                    progress: None,
                    indexer: d.indexer,
                    download_client: d.download_client,
                    error_message: d.error_message,
                    inserted_at: d.inserted_at.0.to_rfc3339(),
                    completed_at: d.completed_at.map(|dt| dt.0.to_rfc3339()),
                    media_item_title: m.map(|m| m.title.clone()),
                    media_item_id: m.map(|m| m.id.to_string()),
                    media_item_type: m.map(|m| m.r#type.clone()),
                    episode_season: e.map(|e| i64::from(e.season_number)),
                    episode_number: e.map(|e| i64::from(e.episode_number)),
                    bytes_pulled: d.bytes_pulled,
                    import_failed_at: d.import_failed_at.map(|dt| dt.0.to_rfc3339()),
                    match_status: d.match_status,
                }
            })
            .collect())
    }

    /// Coarse status derived from the surviving columns. Mirrors the
    /// in-memory branch in `Mydia.Downloads.History` for the case
    /// where the adapter is unreachable (no live torrent state), which
    /// is the only state the Rust port can observe today.
    fn derive_status(
        completed_at: Option<&chrono::DateTime<chrono::Utc>>,
        imported_at: Option<&chrono::DateTime<chrono::Utc>>,
        import_failed_at: Option<&chrono::DateTime<chrono::Utc>>,
    ) -> &'static str {
        if imported_at.is_some() {
            "imported"
        } else if import_failed_at.is_some() {
            "failed"
        } else if completed_at.is_some() {
            "completed"
        } else {
            "active"
        }
    }
}
