//! Import-media server functions — the search, match, and finalize
//! steps of the library-import flow.
//!
//! Phoenix counterpart: `MydiaWeb.ImportMediaLive.Index` plus
//! `Mydia.Library.MetadataMatcher` and `Mydia.Library.MetadataEnricher`.
//! The full Phoenix surface is ~6k LOC across the `LiveView`, its
//! components, and the matching pipeline; the Rust port intentionally
//! ships a thinner three-step flow (search a title, pick a candidate,
//! finalize against an existing `media_files` row or as a fresh
//! library entry) and TODOs the heavyweight pieces (file grouping,
//! bulk season pickers, hardlink/move plans).
//!
//! ## Music / Books / Adult are deprecated
//!
//! The search and finalize boundaries reject anything that isn't
//! `"movie"` or `"tv_show"`. The metadata-relay can occasionally
//! return `Book` results when the operator's query matches a book
//! title; those are filtered out before the candidates reach the
//! page.
//!
//! ## Wire layout
//!
//! - `search_candidates(query, media_type)` returns
//!   `Vec<ImportCandidate>`. Lightweight (just the fields the search
//!   results grid needs).
//! - `fetch_candidate_details(provider, external_id, media_type)`
//!   returns `ImportCandidateDetails` — the full payload the match
//!   step needs to render its detail card.
//! - `finalize_import(provider, external_id, media_type, file_id?,
//!   category_override?)` writes the `media_items` row (insert or
//!   update), optionally associates a `media_files` row, dispatches
//!   the metadata-refresh job, and returns the new `media_item_id`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Wire payload for the search step.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportSearchQuery {
    pub query: String,
    /// `"movie"` or `"tv_show"`. Unknown values coerce to `"movie"`.
    #[serde(default = "default_media_type")]
    pub media_type: String,
}

fn default_media_type() -> String {
    "movie".to_owned()
}

/// One row in the search results grid. Mirrors
/// `AddMediaCandidate` field-for-field so the page can reuse the
/// existing `CandidateCard` component without a translation layer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportCandidate {
    pub provider: String,
    pub external_id: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub release_date: Option<String>,
    /// `"movie"` or `"tv_show"`. Books are filtered out at the server
    /// boundary so callers never see them here.
    pub media_type: String,
}

/// Payload for the candidate-detail fetch (the "match" step). Holds
/// the full metadata the operator needs to disambiguate between two
/// hits that share a title.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportCandidateDetails {
    pub provider: String,
    pub external_id: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub overview: Option<String>,
    pub tagline: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub release_date: Option<String>,
    pub runtime: Option<i32>,
    pub genres: Vec<String>,
    pub production_countries: Vec<String>,
    pub original_language: Option<String>,
    pub alternative_titles: Vec<String>,
    pub homepage: Option<String>,
    pub media_type: String,
    /// TV-only — total number of seasons reported upstream.
    pub number_of_seasons: Option<i32>,
    /// TV-only — total number of episodes reported upstream.
    pub number_of_episodes: Option<i32>,
}

/// Wire payload for finalize. Carries the chosen candidate plus an
/// optional file association (operator picked an unmatched
/// `media_files` row in step 1) and an optional category override
/// (operator forced `movie` over `tv_show` or vice-versa).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportFinalize {
    pub provider: String,
    pub external_id: String,
    pub media_type: String,
    /// `media_files.id` when finalizing against an orphan file.
    /// `None` for a metadata-only library add (no on-disk file yet).
    #[serde(default)]
    pub file_id: Option<String>,
    /// Operator-chosen `category` override (`"movie"` / `"tv_show"`).
    /// Defaults to the candidate's `media_type` when omitted.
    #[serde(default)]
    pub category_override: Option<String>,
}

/// Result of finalize — returns the `media_items.id` so the page can
/// navigate to `/media/<id>`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportFinalizeAck {
    pub media_item_id: String,
    /// True when a fresh `media_items` row was inserted; false when
    /// the operator picked a candidate that already lives in the
    /// library (de-dup by `tmdb_id` + `type`).
    pub created: bool,
    /// True when a `media_files` row was associated to the chosen
    /// `media_item`. False when the operator finalized without a
    /// file (metadata-only add).
    pub file_associated: bool,
    /// True when the metadata-refresh worker was successfully
    /// enqueued. False when the dispatcher wasn't wired into
    /// `WebState` (see TODO).
    pub metadata_refresh_dispatched: bool,
}

#[post("/api/import_media/search")]
pub async fn search_candidates(
    query: ImportSearchQuery,
) -> Result<Vec<ImportCandidate>, ServerFnError> {
    server::search(query).await
}

#[post("/api/import_media/details")]
pub async fn fetch_candidate_details(
    payload: ImportCandidateRef,
) -> Result<ImportCandidateDetails, ServerFnError> {
    server::details(payload).await
}

/// Argument shape for `fetch_candidate_details`. Carries the same
/// `(provider, external_id, media_type)` tuple the search step
/// surfaces.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportCandidateRef {
    pub provider: String,
    pub external_id: String,
    pub media_type: String,
}

#[post("/api/import_media/finalize")]
pub async fn finalize_import(payload: ImportFinalize) -> Result<ImportFinalizeAck, ServerFnError> {
    server::finalize(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{
        ImportCandidate, ImportCandidateDetails, ImportCandidateRef, ImportFinalize,
        ImportFinalizeAck, ImportSearchQuery,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;
    use mydia_rs_metadata::provider::{FetchOpts, Provider, ProviderConfig, SearchOpts};
    use mydia_rs_metadata::relay::Relay;
    use mydia_rs_metadata::structs::{MediaMetadata, MediaType, ProviderKind, SearchResult};

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn search(
        query: ImportSearchQuery,
    ) -> Result<Vec<ImportCandidate>, ServerFnError> {
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

        // Filter out Book results before the candidates leave the
        // server. The relay sometimes returns book hits when the
        // operator's query matches a title; music/adult never reach
        // here because the upstream `MediaType` enum doesn't have
        // those variants.
        Ok(results
            .into_iter()
            .filter(|r| !matches!(r.media_type, MediaType::Book))
            .map(into_candidate)
            .collect())
    }

    pub(super) async fn details(
        payload: ImportCandidateRef,
    ) -> Result<ImportCandidateDetails, ServerFnError> {
        require_session_user_id().await?;
        let media_type = parse_media_type(&payload.media_type);
        let provider_pref = parse_provider_pref(&payload.provider);
        let opts = FetchOpts {
            media_type: Some(media_type),
            provider: provider_pref,
            ..Default::default()
        };
        let config = ProviderConfig::metadata_relay_default();
        let relay = Relay::new();
        let metadata = relay
            .fetch_by_id(&config, &payload.external_id, &opts)
            .await
            .map_err(|err| ServerFnError::new(format!("metadata-relay: {err}")))?;

        Ok(into_details(&payload, metadata))
    }

    pub(super) async fn finalize(
        payload: ImportFinalize,
    ) -> Result<ImportFinalizeAck, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        let media_type = match payload
            .category_override
            .as_deref()
            .unwrap_or(payload.media_type.as_str())
        {
            "movie" => "movie",
            "tv_show" => "tv_show",
            other => {
                return Err(ServerFnError::new(format!("invalid media type {other:?}")));
            }
        };

        // The de-dup check mirrors Phoenix's
        // `unique_index(:media_items, [:tmdb_id])` — when the chosen
        // candidate already lives in the library (operator
        // re-discovered the same TMDB id) we associate the file
        // against the existing row instead of inserting a duplicate.
        let tmdb_id: Option<i64> = if payload.provider == "tmdb" {
            payload.external_id.parse().ok()
        } else {
            None
        };

        let (media_item_id, created) =
            if let Some(existing) = find_by_tmdb(&st.db, tmdb_id, media_type).await? {
                (existing, false)
            } else {
                let id = uuid::Uuid::new_v4().to_string();
                insert_media_item(&st.db, &id, media_type, &payload, tmdb_id).await?;
                (id, true)
            };

        let file_associated = if let Some(file_id) = payload.file_id.as_deref() {
            associate_file(&st.db, file_id, &media_item_id).await?;
            true
        } else {
            false
        };

        // TODO(U27.import-followup): once the metadata-refresh job
        // storage is wired into `WebState`, push a
        // `MetadataRefreshArgs { media_item_id: Some(id), ... }`
        // here. For now the row is created without the heavyweight
        // refresh; the next admin "Refresh metadata" tick picks it
        // up. The Phoenix flow dispatches eagerly via Oban.
        let metadata_refresh_dispatched = false;

        Ok(ImportFinalizeAck {
            media_item_id,
            created,
            file_associated,
            metadata_refresh_dispatched,
        })
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

    async fn insert_media_item(
        db: &Db,
        id: &str,
        media_type: &str,
        payload: &ImportFinalize,
        tmdb_id: Option<i64>,
    ) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        match db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO media_items (id, type, title, tmdb_id, monitored, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(id)
                .bind(media_type)
                .bind(format!("(pending refresh) {}", payload.external_id))
                .bind(tmdb_id)
                .bind(true)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create media_item: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO media_items (id, type, title, tmdb_id, monitored, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7)",
                )
                .bind(id)
                .bind(media_type)
                .bind(format!("(pending refresh) {}", payload.external_id))
                .bind(tmdb_id)
                .bind(true)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create media_item: {err}")))?;
            }
        }
        Ok(())
    }

    async fn associate_file(
        db: &Db,
        file_id: &str,
        media_item_id: &str,
    ) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        let affected = match db {
            Db::Sqlite(pool) => {
                sqlx::query("UPDATE media_files SET media_item_id = ?, updated_at = ? WHERE id = ?")
                    .bind(media_item_id)
                    .bind(now.to_rfc3339())
                    .bind(file_id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("associate file: {err}")))?
                    .rows_affected()
            }
            Db::Postgres(pool) => sqlx::query(
                "UPDATE media_files SET media_item_id = $1, updated_at = $2 WHERE id = $3",
            )
            .bind(media_item_id)
            .bind(now)
            .bind(file_id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("associate file: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no media_files row with id {file_id}"
            )));
        }
        Ok(())
    }

    fn parse_media_type(s: &str) -> MediaType {
        match s {
            "tv_show" | "tv" => MediaType::TvShow,
            _ => MediaType::Movie,
        }
    }

    fn parse_provider_pref(s: &str) -> Option<&'static str> {
        match s {
            "tmdb" => Some("tmdb"),
            "tvdb" => Some("tvdb"),
            _ => None,
        }
    }

    fn into_candidate(r: SearchResult) -> ImportCandidate {
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
        // Book results are filtered upstream; coerce defensively to
        // "movie" if one slips through (the match should never fire).
        let media_type = match r.media_type {
            MediaType::TvShow => "tv_show".to_owned(),
            MediaType::Movie | MediaType::Book => "movie".to_owned(),
        };
        ImportCandidate {
            provider: provider_kind_to_str(r.provider),
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

    fn into_details(payload: &ImportCandidateRef, m: MediaMetadata) -> ImportCandidateDetails {
        let title = m.title.clone().unwrap_or_else(|| "(Untitled)".to_owned());
        let media_type = match m.media_type {
            MediaType::TvShow => "tv_show".to_owned(),
            MediaType::Movie | MediaType::Book => "movie".to_owned(),
        };
        let release_date = m
            .release_date
            .map(|d| d.format("%Y-%m-%d").to_string())
            .or_else(|| m.first_air_date.map(|d| d.format("%Y-%m-%d").to_string()));
        ImportCandidateDetails {
            provider: payload.provider.clone(),
            external_id: payload.external_id.clone(),
            title,
            original_title: m.original_title,
            year: m.year,
            overview: m.overview,
            tagline: m.tagline,
            poster_path: m.poster_path,
            backdrop_path: m.backdrop_path,
            release_date,
            runtime: m.runtime,
            genres: m.genres,
            production_countries: m.production_countries,
            original_language: m.original_language,
            alternative_titles: m.alternative_titles,
            homepage: m.homepage,
            media_type,
            number_of_seasons: m.number_of_seasons,
            number_of_episodes: m.number_of_episodes,
        }
    }

    fn provider_kind_to_str(kind: ProviderKind) -> String {
        match kind {
            ProviderKind::Tmdb => "tmdb".to_owned(),
            ProviderKind::Tvdb => "tvdb".to_owned(),
            ProviderKind::MetadataRelay => "metadata_relay".to_owned(),
            ProviderKind::OpenLibrary => "open_library".to_owned(),
            ProviderKind::MusicRelay => "music_relay".to_owned(),
        }
    }

    fn year_from_iso(s: &str) -> Option<i32> {
        s.split('-').next().and_then(|y| y.parse().ok())
    }
}
