//! Media list server functions (U25.a — movies / tv-shows index).
//!
//! Read-only port of `MydiaWeb.MediaLive.Index`'s data path. The Phoenix
//! `LiveView` loads every matching media item up front and slices client-
//! side; the Rust port keeps the slicing in SQL so a large library
//! doesn't ship 10k rows over the WebSocket on every filter change.
//!
//! Scope is deliberately narrow to match U24.f's minimalism: kind
//! routing (movies vs tv), case-insensitive title search, monitored
//! filter, six sort modes (title/year/added × asc/desc), offset
//! pagination with a "load more" affordance. The richer Phoenix
//! surface — selection mode, batch operations, modals, real-time scan
//! progress, quality / library-type filters — lands in U25.c.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Initial page size. Mirrors the Phoenix `@items_per_page` constant
/// at `lib/mydia_web/live/media_live/index.ex:11` so the first paint
/// fills the grid at the same density operators are used to.
pub const FIRST_PAGE_SIZE: u32 = 50;

/// Each subsequent "load more" page. Mirrors `@items_per_scroll` at
/// `lib/mydia_web/live/media_live/index.ex:12`.
pub const NEXT_PAGE_SIZE: u32 = 25;

/// Sort key — driven by the Phoenix dropdown's value strings so the
/// wire shape stays muscle-memory compatible. Unknown values fall back
/// to `title_asc` on the server side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MediaSort {
    #[default]
    TitleAsc,
    TitleDesc,
    YearAsc,
    YearDesc,
    AddedAsc,
    AddedDesc,
}

impl MediaSort {
    pub fn parse(s: &str) -> Self {
        match s {
            "title_desc" => Self::TitleDesc,
            "year_asc" => Self::YearAsc,
            "year_desc" => Self::YearDesc,
            "added_asc" => Self::AddedAsc,
            "added_desc" => Self::AddedDesc,
            _ => Self::TitleAsc,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::TitleAsc => "title_asc",
            Self::TitleDesc => "title_desc",
            Self::YearAsc => "year_asc",
            Self::YearDesc => "year_desc",
            Self::AddedAsc => "added_asc",
            Self::AddedDesc => "added_desc",
        }
    }
}

/// Monitored filter — `nil` means "all", matching the Phoenix dropdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MonitoredFilter {
    #[default]
    All,
    Monitored,
    Unmonitored,
}

impl MonitoredFilter {
    pub fn parse(s: &str) -> Self {
        match s {
            "true" | "monitored" => Self::Monitored,
            "false" | "unmonitored" => Self::Unmonitored,
            _ => Self::All,
        }
    }
}

/// Wire payload for the index page request — what the filter form
/// drives. `kind` is set by the route (`/movies` vs `/tv`) and is not
/// user-editable from this page.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaQuery {
    /// `"movie"` or `"tv_show"`. Server coerces unknown values to
    /// `"movie"` to match Phoenix's default filter behavior.
    pub kind: String,
    /// Case-insensitive substring search against `title`. Empty means
    /// no search filter.
    #[serde(default)]
    pub search: String,
    #[serde(default)]
    pub monitored: MonitoredFilter,
    #[serde(default)]
    pub sort: MediaSort,
    /// 0-based page index. Page 0 returns the first 50 rows; subsequent
    /// pages return 25 rows each, mirroring the Phoenix `LiveView`.
    #[serde(default)]
    pub page: u32,
}

impl MediaQuery {
    pub fn new(kind: &str) -> Self {
        Self {
            kind: kind.to_owned(),
            search: String::new(),
            monitored: MonitoredFilter::default(),
            sort: MediaSort::default(),
            page: 0,
        }
    }
}

/// One row in the media grid. Only the fields the card renders; the
/// detail page (U25.b) reads the full row via a separate server fn.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaListItem {
    pub id: String,
    pub title: String,
    pub year: Option<i32>,
    /// TMDB-relative poster path (e.g. `/abc123.jpg`). The page renders
    /// it through the `https://image.tmdb.org/t/p/w342` prefix; `None`
    /// means we fall back to the placeholder.
    pub poster_path: Option<String>,
    pub monitored: bool,
    /// `true` when at least one non-trashed `media_files` row exists
    /// for this item (movie) or any of its episodes (tv). Drives the
    /// `MediaListItem` "available locally" badge.
    pub has_files: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaListPage {
    pub items: Vec<MediaListItem>,
    pub page: u32,
    /// `true` when another page is available — drives the "Load more"
    /// button's enabled state.
    pub has_more: bool,
    /// Total matching rows across all pages. Surfaces as "N of M" in
    /// the page header.
    pub total: i64,
}

#[post("/api/media/list")]
pub async fn list_media(query: MediaQuery) -> Result<MediaListPage, ServerFnError> {
    server::list_media(query).await
}

// ---------- U25.b: detail page wire types ----------

/// Headline view for `/media/:id`. Flattens the fields the detail page
/// needs from `media_items` plus the JSON `metadata` blob so the
/// component doesn't deserialize JSON itself. Matches the surface
/// `MydiaWeb.MediaLive.Show` renders before its sub-components walk
/// the file/episode tree.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MediaDetail {
    pub id: String,
    /// `"movie"` or `"tv_show"`. Drives the page's branch between
    /// "single file" rendering (movie) and "seasons + episodes" tree
    /// (tv).
    pub kind: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub overview: Option<String>,
    /// TMDB-relative path; the component owns the base URL.
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    /// Minutes — for tv shows this is per-episode runtime.
    pub runtime: Option<i32>,
    /// TMDB-style 0..10 rating. `None` when the relay never returned
    /// one (e.g. very new release).
    pub rating: Option<f64>,
    pub genres: Vec<String>,
    pub monitored: bool,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
}

/// One row in the movie's "files available" list. Pruned compared to
/// the full `MediaFile` model; only the fields the row renders.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaFileSummary {
    pub id: String,
    pub path: String,
    /// Last segment of `path`, computed server-side so the component
    /// renders without filesystem-aware helpers in wasm.
    pub filename: String,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub size: Option<i64>,
}

/// One episode in the tv show's seasons tree.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EpisodeView {
    pub id: String,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub title: Option<String>,
    /// `YYYY-MM-DD` or empty when unknown.
    pub air_date: String,
    pub monitored: bool,
    pub has_files: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SeasonView {
    pub season_number: i32,
    pub episode_count: i32,
    pub downloaded_count: i32,
    pub episodes: Vec<EpisodeView>,
}

#[post("/api/media/detail")]
pub async fn get_media_detail(id: String) -> Result<MediaDetail, ServerFnError> {
    server::get_media_detail(&id).await
}

#[post("/api/media/files")]
pub async fn list_media_files(id: String) -> Result<Vec<MediaFileSummary>, ServerFnError> {
    server::list_media_files(&id).await
}

#[post("/api/media/seasons")]
pub async fn list_media_seasons(id: String) -> Result<Vec<SeasonView>, ServerFnError> {
    server::list_media_seasons(&id).await
}

#[cfg(feature = "server")]
pub mod server {
    //! Server-only SQL helpers powering `list_media`. The inner
    //! functions are `pub` so integration tests can drive them against
    //! a real fixture pool without spinning up the full axum +
    //! `FullstackContext` plumbing.

    use super::{
        EpisodeView, MediaDetail, MediaFileSummary, MediaListItem, MediaListPage, MediaQuery,
        MediaSort, MonitoredFilter, SeasonView, FIRST_PAGE_SIZE, NEXT_PAGE_SIZE,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;
    use mydia_rs_models::MediaItem;
    use sqlx::{Postgres, QueryBuilder, Sqlite};
    use std::collections::BTreeMap;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    /// Restrict to the two values the index page actually drives.
    /// Unknown kinds collapse to `"movie"` so a malformed request
    /// degrades to a sensible default rather than 500.
    fn sanitize_kind(s: &str) -> &'static str {
        match s {
            "tv_show" | "tv" => "tv_show",
            _ => "movie",
        }
    }

    pub(super) async fn list_media(query: MediaQuery) -> Result<MediaListPage, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        let kind = sanitize_kind(&query.kind);
        let search = query.search.trim();
        let search = if search.is_empty() {
            None
        } else {
            Some(search)
        };

        // Pagination math mirrors load_media_items/2 — first page is
        // larger (50) and subsequent pages are smaller (25). Offsets
        // line up so page 1 starts at row 50, page 2 at row 75, etc.
        let (offset, limit) = if query.page == 0 {
            (0u32, FIRST_PAGE_SIZE)
        } else {
            let offset = FIRST_PAGE_SIZE + (query.page - 1) * NEXT_PAGE_SIZE;
            (offset, NEXT_PAGE_SIZE)
        };

        let total = count_media(&st.db, kind, query.monitored, search).await?;
        let rows = fetch_media(
            &st.db,
            kind,
            query.monitored,
            search,
            query.sort,
            offset,
            limit,
        )
        .await?;

        let mut items = Vec::with_capacity(rows.len());
        for row in &rows {
            let has_files = row_has_files(&st.db, &row.id.0.to_string(), kind).await?;
            items.push(into_list_item(row, has_files));
        }

        let has_more = i64::from(offset + limit) < total;
        Ok(MediaListPage {
            items,
            page: query.page,
            has_more,
            total,
        })
    }

    pub async fn count_media(
        db: &Db,
        kind: &str,
        monitored: MonitoredFilter,
        search: Option<&str>,
    ) -> Result<i64, ServerFnError> {
        match db {
            Db::Sqlite(pool) => {
                let mut qb: QueryBuilder<Sqlite> =
                    QueryBuilder::new("SELECT COUNT(*) FROM media_items WHERE type = ");
                qb.push_bind(kind.to_owned());
                push_monitored_filter_sqlite(&mut qb, monitored);
                push_search_filter_sqlite(&mut qb, search);
                let (n,): (i64,) = qb
                    .build_query_as()
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count media: {err}")))?;
                Ok(n)
            }
            Db::Postgres(pool) => {
                let mut qb: QueryBuilder<Postgres> =
                    QueryBuilder::new("SELECT COUNT(*) FROM media_items WHERE type = ");
                qb.push_bind(kind.to_owned());
                push_monitored_filter_pg(&mut qb, monitored);
                push_search_filter_pg(&mut qb, search);
                let (n,): (i64,) = qb
                    .build_query_as()
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count media: {err}")))?;
                Ok(n)
            }
        }
    }

    pub async fn fetch_media(
        db: &Db,
        kind: &str,
        monitored: MonitoredFilter,
        search: Option<&str>,
        sort: MediaSort,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<MediaItem>, ServerFnError> {
        // Column list mirrors crates/graphql/src/repos/media.rs so the
        // sqlx FromRow impl on MediaItem decodes cleanly. SELECT * is
        // banned per the plan; explicit columns keep additive Phoenix
        // migrations tolerated without breaking decode.
        const COLS: &str = "id, type, title, original_title, year, tmdb_id, tvdb_id, imdb_id, \
                            metadata, monitored, monitoring_preset, category, category_override, \
                            seasons_refreshed_at, quality_profile_id, inserted_at, updated_at";

        match db {
            Db::Sqlite(pool) => {
                let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("SELECT ");
                qb.push(COLS);
                qb.push(" FROM media_items WHERE type = ");
                qb.push_bind(kind.to_owned());
                push_monitored_filter_sqlite(&mut qb, monitored);
                push_search_filter_sqlite(&mut qb, search);
                push_order_sqlite(&mut qb, sort);
                qb.push(" LIMIT ").push_bind(i64::from(limit));
                qb.push(" OFFSET ").push_bind(i64::from(offset));
                qb.build_query_as::<MediaItem>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list media: {err}")))
            }
            Db::Postgres(pool) => {
                let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("SELECT ");
                qb.push(COLS);
                qb.push(" FROM media_items WHERE type = ");
                qb.push_bind(kind.to_owned());
                push_monitored_filter_pg(&mut qb, monitored);
                push_search_filter_pg(&mut qb, search);
                push_order_pg(&mut qb, sort);
                qb.push(" LIMIT ").push_bind(i64::from(limit));
                qb.push(" OFFSET ").push_bind(i64::from(offset));
                qb.build_query_as::<MediaItem>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list media: {err}")))
            }
        }
    }

    /// EXISTS subquery against `media_files` for the "available locally"
    /// badge. Movies check the direct `media_item_id` FK; TV shows go
    /// one hop further through `episodes`. Both forms filter out
    /// trashed files since the Phoenix `LiveView` preloads exclude them
    /// (see `active_files_query` at index.ex:658).
    pub async fn row_has_files(db: &Db, id: &str, kind: &str) -> Result<bool, ServerFnError> {
        let sql_sqlite = if kind == "tv_show" {
            "SELECT EXISTS(\
               SELECT 1 FROM media_files mf \
               JOIN episodes e ON mf.episode_id = e.id \
               WHERE e.media_item_id = ? AND mf.trashed_at IS NULL)"
        } else {
            "SELECT EXISTS(\
               SELECT 1 FROM media_files \
               WHERE media_item_id = ? AND trashed_at IS NULL)"
        };
        let sql_pg = if kind == "tv_show" {
            "SELECT EXISTS(\
               SELECT 1 FROM media_files mf \
               JOIN episodes e ON mf.episode_id = e.id \
               WHERE e.media_item_id = $1 AND mf.trashed_at IS NULL)"
        } else {
            "SELECT EXISTS(\
               SELECT 1 FROM media_files \
               WHERE media_item_id = $1 AND trashed_at IS NULL)"
        };

        match db {
            Db::Sqlite(pool) => {
                let (has,): (bool,) = sqlx::query_as(sql_sqlite)
                    .bind(id)
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("has_files: {err}")))?;
                Ok(has)
            }
            Db::Postgres(pool) => {
                let (has,): (bool,) = sqlx::query_as(sql_pg)
                    .bind(id)
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("has_files: {err}")))?;
                Ok(has)
            }
        }
    }

    fn push_monitored_filter_sqlite(qb: &mut QueryBuilder<'_, Sqlite>, monitored: MonitoredFilter) {
        match monitored {
            MonitoredFilter::All => {}
            MonitoredFilter::Monitored => {
                qb.push(" AND monitored = 1");
            }
            MonitoredFilter::Unmonitored => {
                qb.push(" AND monitored = 0");
            }
        }
    }

    fn push_monitored_filter_pg(qb: &mut QueryBuilder<'_, Postgres>, monitored: MonitoredFilter) {
        match monitored {
            MonitoredFilter::All => {}
            MonitoredFilter::Monitored => {
                qb.push(" AND monitored = true");
            }
            MonitoredFilter::Unmonitored => {
                qb.push(" AND monitored = false");
            }
        }
    }

    fn push_search_filter_sqlite(qb: &mut QueryBuilder<'_, Sqlite>, search: Option<&str>) {
        if let Some(term) = search {
            let pattern = format!("%{}%", term.to_lowercase());
            qb.push(" AND lower(title) LIKE ").push_bind(pattern);
        }
    }

    fn push_search_filter_pg(qb: &mut QueryBuilder<'_, Postgres>, search: Option<&str>) {
        if let Some(term) = search {
            let pattern = format!("%{}%", term.to_lowercase());
            qb.push(" AND lower(title) LIKE ").push_bind(pattern);
        }
    }

    fn push_order_sqlite(qb: &mut QueryBuilder<'_, Sqlite>, sort: MediaSort) {
        // SQLite uses `COLLATE NOCASE` for case-insensitive title sort;
        // Postgres uses `lower(title)`. Year and date sorts are
        // dialect-agnostic. We treat NULL years as 0 so they sink to
        // the bottom on `year_asc`, mirroring Phoenix's `&(&1.year || 0)`.
        match sort {
            MediaSort::TitleAsc => {
                qb.push(" ORDER BY title COLLATE NOCASE ASC");
            }
            MediaSort::TitleDesc => {
                qb.push(" ORDER BY title COLLATE NOCASE DESC");
            }
            MediaSort::YearAsc => {
                qb.push(" ORDER BY COALESCE(year, 0) ASC, title COLLATE NOCASE ASC");
            }
            MediaSort::YearDesc => {
                qb.push(" ORDER BY COALESCE(year, 0) DESC, title COLLATE NOCASE ASC");
            }
            MediaSort::AddedAsc => {
                qb.push(" ORDER BY inserted_at ASC");
            }
            MediaSort::AddedDesc => {
                qb.push(" ORDER BY inserted_at DESC");
            }
        }
    }

    fn push_order_pg(qb: &mut QueryBuilder<'_, Postgres>, sort: MediaSort) {
        match sort {
            MediaSort::TitleAsc => {
                qb.push(" ORDER BY lower(title) ASC");
            }
            MediaSort::TitleDesc => {
                qb.push(" ORDER BY lower(title) DESC");
            }
            MediaSort::YearAsc => {
                qb.push(" ORDER BY COALESCE(year, 0) ASC, lower(title) ASC");
            }
            MediaSort::YearDesc => {
                qb.push(" ORDER BY COALESCE(year, 0) DESC, lower(title) ASC");
            }
            MediaSort::AddedAsc => {
                qb.push(" ORDER BY inserted_at ASC");
            }
            MediaSort::AddedDesc => {
                qb.push(" ORDER BY inserted_at DESC");
            }
        }
    }

    pub fn into_list_item(row: &MediaItem, has_files: bool) -> MediaListItem {
        // Phoenix's `MydiaWeb.MediaHelpers.get_poster_url/1` reads
        // `metadata.poster_path` and prepends the TMDB base URL. We
        // surface just the path here; the card component owns the
        // base URL so the size segment can be tuned per-density later.
        let poster_path = row
            .metadata
            .as_ref()
            .and_then(|m| m.0.get("poster_path"))
            .and_then(|v| v.as_str())
            .map(std::borrow::ToOwned::to_owned);

        MediaListItem {
            id: row.id.0.to_string(),
            title: row.title.clone().unwrap_or_default(),
            year: row.year,
            poster_path,
            monitored: row.monitored,
            has_files,
        }
    }

    // ---------- U25.b: detail page server logic ----------

    pub(super) async fn get_media_detail(id: &str) -> Result<MediaDetail, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        fetch_media_detail(&st.db, id).await
    }

    pub(super) async fn list_media_files(id: &str) -> Result<Vec<MediaFileSummary>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        fetch_movie_files(&st.db, id).await
    }

    pub(super) async fn list_media_seasons(id: &str) -> Result<Vec<SeasonView>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        fetch_show_seasons(&st.db, id).await
    }

    pub async fn fetch_media_detail(db: &Db, id: &str) -> Result<MediaDetail, ServerFnError> {
        const COLS: &str = "id, type, title, original_title, year, tmdb_id, tvdb_id, imdb_id, \
                            metadata, monitored, monitoring_preset, category, category_override, \
                            seasons_refreshed_at, quality_profile_id, inserted_at, updated_at";

        let row: Option<MediaItem> = match db {
            Db::Sqlite(pool) => {
                let sql = format!("SELECT {COLS} FROM media_items WHERE id = ?");
                sqlx::query_as::<_, MediaItem>(&sql)
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("detail: {err}")))?
            }
            Db::Postgres(pool) => {
                let sql = format!("SELECT {COLS} FROM media_items WHERE id = $1");
                sqlx::query_as::<_, MediaItem>(&sql)
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("detail: {err}")))?
            }
        };

        let row = row.ok_or_else(|| ServerFnError::new("Media item not found"))?;
        Ok(into_detail(&row))
    }

    fn into_detail(row: &MediaItem) -> MediaDetail {
        // The metadata blob holds the bulk of the headline fields —
        // overview, poster_path, backdrop_path, runtime, genres,
        // vote_average. Phoenix's `Mydia.Metadata.Structs.MediaMetadata`
        // typed struct is the source of truth; we read the JSON here
        // because the typed mirror isn't ported yet (the metadata
        // crate ships its own structs, separate from this page's
        // wire shape).
        let metadata = row.metadata.as_ref().map(|m| &m.0);
        let get_str = |k: &str| -> Option<String> {
            metadata
                .and_then(|m| m.get(k))
                .and_then(|v| v.as_str())
                .map(std::borrow::ToOwned::to_owned)
        };
        let get_i32 = |k: &str| -> Option<i32> {
            metadata
                .and_then(|m| m.get(k))
                .and_then(serde_json::Value::as_i64)
                .and_then(|n| i32::try_from(n).ok())
        };
        let get_f64 = |k: &str| -> Option<f64> {
            metadata
                .and_then(|m| m.get(k))
                .and_then(serde_json::Value::as_f64)
        };
        let genres = metadata
            .and_then(|m| m.get("genres"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(std::borrow::ToOwned::to_owned))
                    .collect()
            })
            .unwrap_or_default();

        MediaDetail {
            id: row.id.0.to_string(),
            kind: row.r#type.clone().unwrap_or_default(),
            title: row.title.clone().unwrap_or_default(),
            original_title: row.original_title.clone(),
            year: row.year,
            overview: get_str("overview"),
            poster_path: get_str("poster_path"),
            backdrop_path: get_str("backdrop_path"),
            runtime: get_i32("runtime"),
            rating: get_f64("vote_average"),
            genres,
            monitored: row.monitored,
            tmdb_id: row.tmdb_id,
            tvdb_id: row.tvdb_id,
            imdb_id: row.imdb_id.clone(),
        }
    }

    pub async fn fetch_movie_files(
        db: &Db,
        movie_id: &str,
    ) -> Result<Vec<MediaFileSummary>, ServerFnError> {
        // Direct fk path only — episode files are surfaced via the
        // seasons tree, not this list. Trashed files excluded to match
        // the Phoenix `active_files_query` preload.
        const COLS: &str = "id, path, resolution, codec, audio_codec, size";
        type Row = (
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i64>,
        );
        let rows: Vec<Row> = match db {
            Db::Sqlite(pool) => sqlx::query_as(&format!(
                "SELECT {COLS} FROM media_files \
                          WHERE media_item_id = ? AND trashed_at IS NULL \
                          ORDER BY \
                            CASE resolution \
                              WHEN '2160p' THEN 0 \
                              WHEN '1080p' THEN 1 \
                              WHEN '720p' THEN 2 \
                              WHEN '480p' THEN 3 \
                              ELSE 4 END ASC, \
                            path ASC"
            ))
            .bind(movie_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("movie files: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(&format!(
                "SELECT {COLS} FROM media_files \
                          WHERE media_item_id = $1 AND trashed_at IS NULL \
                          ORDER BY \
                            CASE resolution \
                              WHEN '2160p' THEN 0 \
                              WHEN '1080p' THEN 1 \
                              WHEN '720p' THEN 2 \
                              WHEN '480p' THEN 3 \
                              ELSE 4 END ASC, \
                            path ASC"
            ))
            .bind(movie_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("movie files: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(|(id, path, resolution, codec, audio_codec, size)| {
                let path = path.unwrap_or_default();
                let filename = path.rsplit('/').next().unwrap_or(&path).to_owned();
                MediaFileSummary {
                    id,
                    path,
                    filename,
                    resolution,
                    codec,
                    audio_codec,
                    size,
                }
            })
            .collect())
    }

    pub async fn fetch_show_seasons(
        db: &Db,
        show_id: &str,
    ) -> Result<Vec<SeasonView>, ServerFnError> {
        // Two queries: all episodes for the show, then all non-trashed
        // media_files that reference any of those episodes. Group in
        // Rust to avoid an N+1 EXISTS-per-episode loop on a long-running
        // series. Keeps the wire payload small (one struct per episode
        // with a boolean) rather than embedding the full file rows.
        let episode_sql_sqlite =
            "SELECT id, season_number, episode_number, title, air_date, monitored \
                                  FROM episodes \
                                  WHERE media_item_id = ? \
                                  ORDER BY COALESCE(season_number, 0) ASC, \
                                           COALESCE(episode_number, 0) ASC";
        let episode_sql_pg =
            "SELECT id, season_number, episode_number, title, air_date, monitored \
                              FROM episodes \
                              WHERE media_item_id = $1 \
                              ORDER BY COALESCE(season_number, 0) ASC, \
                                       COALESCE(episode_number, 0) ASC";

        type EpisodeRow = (
            String,
            Option<i32>,
            Option<i32>,
            Option<String>,
            Option<chrono::NaiveDate>,
            bool,
        );
        let episode_rows: Vec<EpisodeRow> = match db {
            Db::Sqlite(pool) => sqlx::query_as(episode_sql_sqlite)
                .bind(show_id)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("seasons episodes: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(episode_sql_pg)
                .bind(show_id)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("seasons episodes: {err}")))?,
        };

        // Episode IDs that have at least one non-trashed media file.
        let files_sql_sqlite = "SELECT DISTINCT mf.episode_id \
                                FROM media_files mf \
                                JOIN episodes e ON mf.episode_id = e.id \
                                WHERE e.media_item_id = ? AND mf.trashed_at IS NULL \
                                  AND mf.episode_id IS NOT NULL";
        let files_sql_pg = "SELECT DISTINCT mf.episode_id \
                            FROM media_files mf \
                            JOIN episodes e ON mf.episode_id = e.id \
                            WHERE e.media_item_id = $1 AND mf.trashed_at IS NULL \
                              AND mf.episode_id IS NOT NULL";

        let with_files: Vec<(Option<String>,)> = match db {
            Db::Sqlite(pool) => sqlx::query_as(files_sql_sqlite)
                .bind(show_id)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("seasons files: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(files_sql_pg)
                .bind(show_id)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("seasons files: {err}")))?,
        };
        let with_files: std::collections::HashSet<String> = with_files
            .into_iter()
            .filter_map(|(maybe_id,)| maybe_id)
            .collect();

        // Group episodes by season. BTreeMap so seasons render in order
        // without an extra sort; Vec<EpisodeView> within each season
        // is already in episode order from the SQL ORDER BY above.
        let mut seasons: BTreeMap<i32, Vec<EpisodeView>> = BTreeMap::new();
        for (id, season, episode, title, air_date, monitored) in episode_rows {
            let season_key = season.unwrap_or(0);
            let has_files = with_files.contains(&id);
            let air_date_str = air_date
                .map(|d| d.format("%Y-%m-%d").to_string())
                .unwrap_or_default();
            seasons.entry(season_key).or_default().push(EpisodeView {
                id,
                season_number: season,
                episode_number: episode,
                title,
                air_date: air_date_str,
                monitored,
                has_files,
            });
        }

        Ok(seasons
            .into_iter()
            .map(|(season_number, episodes)| SeasonView {
                season_number,
                episode_count: i32::try_from(episodes.len()).unwrap_or(0),
                downloaded_count: i32::try_from(episodes.iter().filter(|e| e.has_files).count())
                    .unwrap_or(0),
                episodes,
            })
            .collect())
    }
}
