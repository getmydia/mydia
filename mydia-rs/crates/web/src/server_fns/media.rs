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

#[cfg(feature = "server")]
pub mod server {
    //! Server-only SQL helpers powering `list_media`. The inner
    //! functions are `pub` so integration tests can drive them against
    //! a real fixture pool without spinning up the full axum +
    //! `FullstackContext` plumbing.

    use super::{
        MediaListItem, MediaListPage, MediaQuery, MediaSort, MonitoredFilter, FIRST_PAGE_SIZE,
        NEXT_PAGE_SIZE,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;
    use mydia_rs_models::MediaItem;
    use sqlx::{Postgres, QueryBuilder, Sqlite};

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
}
