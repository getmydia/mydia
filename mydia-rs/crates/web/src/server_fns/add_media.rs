//! Add-media (metadata search + library add) server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AddMediaLive.Index`. The Phoenix
//! flow is: search metadata → operator picks a candidate → server
//! creates a `media_items` row keyed by tmdb/tvdb id and starts a
//! metadata-sync job. The Rust port keeps the search and create
//! steps; the metadata-sync job dispatch lands in a follow-up
//! alongside the U17 worker bindings.
//!
//! Music / Books / Adult are deprecated, so `media_type` accepts only
//! `"movie"` and `"tv_show"`. Anything else falls back to `"movie"`
//! at the server boundary.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchQuery {
    pub query: String,
    /// `"movie"` or `"tv_show"`. Unknown values coerce to `"movie"`.
    #[serde(default = "default_media_type")]
    pub media_type: String,
}

fn default_media_type() -> String {
    "movie".to_owned()
}

/// A single metadata-relay search hit. Mirrors the relevant fields
/// from `mydia_rs_metadata::structs::SearchResult` so the page
/// renders without round-tripping through the metadata crate.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AddMediaCandidate {
    pub provider: String,
    /// Provider-side id (TMDB id, TVDB id, IMDB id). Stored verbatim.
    pub external_id: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub release_date: Option<String>,
    pub media_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddMediaSelection {
    pub provider: String,
    pub external_id: String,
    pub title: String,
    pub media_type: String,
    pub year: Option<i32>,
    /// Quality profile id (optional today — once the quality profile
    /// crate exposes a list, this becomes required and validated).
    pub quality_profile_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AddMediaAck {
    pub media_item_id: String,
}

/// One quality-profile picker option — id + display name, no inner
/// detail. Surfaced to non-admin operators on the add-media page so
/// they can pick a profile without needing admin access to the full
/// quality-profile management surface.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QualityProfileOption {
    pub id: String,
    pub name: String,
}

#[post("/api/add_media/search")]
pub async fn search_metadata(query: SearchQuery) -> Result<Vec<AddMediaCandidate>, ServerFnError> {
    server::search(query).await
}

#[post("/api/add_media/create")]
pub async fn add_media_to_library(
    payload: AddMediaSelection,
) -> Result<AddMediaAck, ServerFnError> {
    server::create(payload).await
}

#[get("/api/add_media/quality_profiles")]
pub async fn list_quality_profile_options() -> Result<Vec<QualityProfileOption>, ServerFnError> {
    server::list_quality_profile_options().await
}

#[cfg(feature = "server")]
mod server {
    use super::{
        AddMediaAck, AddMediaCandidate, AddMediaSelection, QualityProfileOption, SearchQuery,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;
    use mydia_rs_metadata::provider::{Provider, ProviderConfig, SearchOpts};
    use mydia_rs_metadata::relay::Relay;
    use mydia_rs_metadata::structs::{MediaType, SearchResult};

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn search(
        query: SearchQuery,
    ) -> Result<Vec<AddMediaCandidate>, ServerFnError> {
        require_session_user_id().await?;
        if query.query.trim().is_empty() {
            return Ok(Vec::new());
        }

        let media_type = parse_media_type(&query.media_type);
        let opts = SearchOpts {
            media_type: Some(media_type),
            ..Default::default()
        };
        let config = ProviderConfig::metadata_relay_default();
        let relay = Relay::new();
        let results = relay
            .search(&config, query.query.trim(), &opts)
            .await
            .map_err(|err| ServerFnError::new(format!("metadata-relay: {err}")))?;

        Ok(results.into_iter().map(into_candidate).collect())
    }

    pub(super) async fn create(payload: AddMediaSelection) -> Result<AddMediaAck, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        // The Phoenix flow validates media_type at the changeset; we
        // do it at the server boundary to keep the error path simple.
        let media_type = match payload.media_type.as_str() {
            "movie" => "movie",
            "tv_show" => "tv_show",
            _ => return Err(ServerFnError::new("Invalid media type")),
        };

        // Quality profile is optional — Phoenix leaves the column null
        // until the operator picks one. The picker on the add-media
        // page now passes through a non-null id when the operator
        // chose a profile; the pipeline downstream defaults to the
        // system profile when this column is null.

        // De-duplicate by (tmdb_id, type) before inserting — the
        // Phoenix changeset has the same unique-index check via
        // `unique_index(:media_items, [:tmdb_id])`.
        let tmdb_id: Option<i64> = if payload.provider == "tmdb" {
            payload.external_id.parse().ok()
        } else {
            None
        };

        if let Some(existing) = find_by_tmdb(&st.db, tmdb_id, media_type).await? {
            return Ok(AddMediaAck {
                media_item_id: existing,
            });
        }

        // Verify the picked quality profile exists before writing the
        // FK. SQLite's default config doesn't enforce foreign keys so
        // a bogus id would silently succeed otherwise.
        let quality_profile_id = payload.quality_profile_id.as_deref();
        if let Some(qp_id) = quality_profile_id {
            if !quality_profile_exists(&st.db, qp_id).await? {
                return Err(ServerFnError::new(format!(
                    "no quality_profile with id {qp_id}"
                )));
            }
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO media_items (id, type, title, year, tmdb_id, quality_profile_id, monitored, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(media_type)
                .bind(&payload.title)
                .bind(payload.year)
                .bind(tmdb_id)
                .bind(quality_profile_id)
                .bind(true)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create media_item: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO media_items (id, type, title, year, tmdb_id, quality_profile_id, monitored, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                )
                .bind(&id)
                .bind(media_type)
                .bind(&payload.title)
                .bind(payload.year)
                .bind(tmdb_id)
                .bind(quality_profile_id)
                .bind(true)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create media_item: {err}")))?;
            }
        }

        Ok(AddMediaAck { media_item_id: id })
    }

    /// Verify a `quality_profile` row exists. Used by [`create`] to
    /// reject bogus FK ids before the insert lands.
    async fn quality_profile_exists(db: &Db, id: &str) -> Result<bool, ServerFnError> {
        let row: Option<(String,)> = match db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT id FROM quality_profiles WHERE id = ? LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("verify quality_profile: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT id FROM quality_profiles WHERE id = $1 LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("verify quality_profile: {err}")))?
            }
        };
        Ok(row.is_some())
    }

    /// Lightweight picker fetch — every quality profile's id + name,
    /// in display order. Session-auth only; the full admin CRUD
    /// surface is gated by admin auth via
    /// `crate::server_fns::admin::quality_profiles::list_quality_profiles`.
    pub(super) async fn list_quality_profile_options(
    ) -> Result<Vec<QualityProfileOption>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let rows: Vec<(String, String)> = match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT id, name FROM quality_profiles ORDER BY name ASC")
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list quality_profiles: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT id, name FROM quality_profiles ORDER BY name ASC")
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list quality_profiles: {err}")))?
            }
        };
        Ok(rows
            .into_iter()
            .map(|(id, name)| QualityProfileOption { id, name })
            .collect())
    }

    async fn find_by_tmdb(
        db: &Db,
        tmdb_id: Option<i64>,
        media_type: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let Some(tmdb_id) = tmdb_id else {
            return Ok(None);
        };
        let row: Option<(String,)> = match db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT id FROM media_items WHERE tmdb_id = ? AND type = ? LIMIT 1")
                    .bind(tmdb_id)
                    .bind(media_type)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("lookup by tmdb_id: {err}")))?
            }
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id FROM media_items WHERE tmdb_id = $1 AND type = $2 LIMIT 1",
            )
            .bind(tmdb_id)
            .bind(media_type)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup by tmdb_id: {err}")))?,
        };
        Ok(row.map(|(id,)| id))
    }

    fn parse_media_type(s: &str) -> MediaType {
        match s {
            "tv_show" | "tv" => MediaType::TvShow,
            _ => MediaType::Movie,
        }
    }

    fn into_candidate(r: SearchResult) -> AddMediaCandidate {
        let title = r
            .title
            .clone()
            .or_else(|| r.name.clone())
            .or_else(|| r.original_title.clone())
            .or_else(|| r.original_name.clone())
            .unwrap_or_else(|| "(Untitled)".to_owned());
        let year = r.year.or_else(|| {
            r.release_date
                .as_deref()
                .or(r.first_air_date.as_deref())
                .and_then(year_from_iso)
        });
        let media_type = match r.media_type {
            MediaType::Movie | MediaType::Book => "movie".to_owned(),
            MediaType::TvShow => "tv_show".to_owned(),
        };
        let provider = match r.provider {
            mydia_rs_metadata::structs::ProviderKind::Tmdb => "tmdb".to_owned(),
            mydia_rs_metadata::structs::ProviderKind::Tvdb => "tvdb".to_owned(),
            mydia_rs_metadata::structs::ProviderKind::MetadataRelay => "metadata_relay".to_owned(),
            mydia_rs_metadata::structs::ProviderKind::OpenLibrary => "open_library".to_owned(),
            mydia_rs_metadata::structs::ProviderKind::MusicRelay => "music_relay".to_owned(),
        };
        AddMediaCandidate {
            provider,
            external_id: r
                .id
                .map_or_else(|| r.provider_id.clone(), |id| id.to_string()),
            title,
            original_title: r.original_title.or(r.original_name),
            year,
            overview: r.overview,
            poster_path: r.poster_path,
            release_date: r.release_date.or(r.first_air_date),
            media_type,
        }
    }

    fn year_from_iso(s: &str) -> Option<i32> {
        s.split('-').next().and_then(|y| y.parse().ok())
    }
}
