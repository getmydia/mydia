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
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::{insert_active_model, DatabaseConnection};
    use mydia_rs_entities::{media_items, quality_profiles};
    use mydia_rs_metadata::provider::{Provider, ProviderConfig, SearchOpts};
    use mydia_rs_metadata::relay::Relay;
    use mydia_rs_metadata::structs::{MediaType, SearchResult};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;

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

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let qp_uuid =
            quality_profile_id.and_then(|s| uuid::Uuid::parse_str(s).ok().map(UuidText::from));
        let tmdb_id_i32 = tmdb_id.and_then(|n| i32::try_from(n).ok());
        let am = media_items::ActiveModel {
            id: Set(id),
            r#type: Set(media_type.to_owned()),
            title: Set(payload.title.clone()),
            original_title: Set(None),
            year: Set(payload.year),
            tmdb_id: Set(tmdb_id_i32),
            imdb_id: Set(None),
            metadata: Set(None),
            monitored: Set(Some(true)),
            inserted_at: Set(now),
            updated_at: Set(now),
            quality_profile_id: Set(qp_uuid),
            category: Set(None),
            category_override: Set(false),
            monitoring_preset: Set(Some("all".to_owned())),
            seasons_refreshed_at: Set(None),
            tvdb_id: Set(None),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("create media_item: {err}")))?;

        Ok(AddMediaAck {
            media_item_id: id_str,
        })
    }

    /// Verify a `quality_profile` row exists. Used by [`create`] to
    /// reject bogus FK ids before the insert lands.
    async fn quality_profile_exists(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<bool, ServerFnError> {
        let Some(wrapper) = uuid::Uuid::parse_str(id).ok().map(UuidText::from) else {
            return Ok(false);
        };
        let backend = db.get_database_backend();
        let count = quality_profiles::Entity::find()
            .filter(Expr::col(quality_profiles::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("verify quality_profile: {err}")))?;
        Ok(count > 0)
    }

    /// Lightweight picker fetch — every quality profile's id + name,
    /// in display order. Session-auth only; the full admin CRUD
    /// surface is gated by admin auth via
    /// `crate::server_fns::admin::quality_profiles::list_quality_profiles`.
    pub(super) async fn list_quality_profile_options(
    ) -> Result<Vec<QualityProfileOption>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let rows = quality_profiles::Entity::find()
            .order_by_asc(quality_profiles::Column::Name)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("list quality_profiles: {err}")))?;
        Ok(rows
            .into_iter()
            .map(|m| QualityProfileOption {
                id: m.id.to_string(),
                name: m.name,
            })
            .collect())
    }

    async fn find_by_tmdb(
        db: &DatabaseConnection,
        tmdb_id: Option<i64>,
        media_type: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let Some(tmdb_id) = tmdb_id else {
            return Ok(None);
        };
        let Some(tmdb_id_i32) = i32::try_from(tmdb_id).ok() else {
            return Ok(None);
        };
        let row = media_items::Entity::find()
            .filter(media_items::Column::TmdbId.eq(tmdb_id_i32))
            .filter(media_items::Column::Type.eq(media_type.to_owned()))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup by tmdb_id: {err}")))?;
        Ok(row.map(|r| r.id.to_string()))
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
