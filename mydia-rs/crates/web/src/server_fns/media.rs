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

// ---------- U25.c: action endpoints (monitor toggle, delete) ----------

/// Result of a monitor toggle — the new state plus a label the page can
/// surface via flash without recomputing on the wire side.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct MonitorToggleAck {
    pub monitored: bool,
}

#[post("/api/media/monitor/toggle")]
pub async fn toggle_media_monitored(id: String) -> Result<MonitorToggleAck, ServerFnError> {
    server::toggle_media_monitored(&id).await
}

#[post("/api/media/episode/monitor/toggle")]
pub async fn toggle_episode_monitored(id: String) -> Result<MonitorToggleAck, ServerFnError> {
    server::toggle_episode_monitored(&id).await
}

/// Body for the delete-from-library action. Files-on-disk deletion is
/// not yet wired (the Phoenix flow does it via `Mydia.Media.delete_media_item`
/// which cascades to `Library.delete_files`); U25.c ships the DB-only
/// path and a later commit adds the disk-deletion path under a
/// `delete_files: true` opt once the worker queue side is ported.
#[post("/api/media/delete")]
pub async fn delete_media(id: String) -> Result<(), ServerFnError> {
    server::delete_media(&id).await
}

#[cfg(feature = "server")]
pub mod server {
    //! Server-only SQL helpers powering `list_media`. The inner
    //! functions are `pub` so integration tests can drive them against
    //! a real fixture pool without spinning up the full axum +
    //! `FullstackContext` plumbing.

    use super::{
        EpisodeView, MediaDetail, MediaFileSummary, MediaListItem, MediaListPage, MediaQuery,
        MediaSort, MonitorToggleAck, MonitoredFilter, SeasonView, FIRST_PAGE_SIZE, NEXT_PAGE_SIZE,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{episodes, media_files, media_items};
    use mydia_rs_models::MediaItem;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{Order, QueryOrder, QuerySelect};
    use sea_orm::sea_query::{Condition, Expr, ExprTrait, Func, Query, SimpleExpr};

    use std::collections::BTreeMap;

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    /// Convert an entity `media_items::Model` into the `MediaItem` model
    /// used by the rest of this module (which has a richer metadata
    /// type and slightly different field types).
    fn model_to_media_item(m: media_items::Model) -> MediaItem {
        MediaItem {
            id: m.id,
            r#type: Some(m.r#type),
            title: Some(m.title),
            original_title: m.original_title,
            year: m.year,
            tmdb_id: m.tmdb_id.map(i64::from),
            tvdb_id: m.tvdb_id.map(i64::from),
            imdb_id: m.imdb_id,
            metadata: m
                .metadata
                .as_deref()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
                .map(JsonMap),
            monitored: m.monitored.unwrap_or(false),
            monitoring_preset: m.monitoring_preset.unwrap_or_else(|| "all".to_owned()),
            category: m.category,
            category_override: m.category_override,
            seasons_refreshed_at: m.seasons_refreshed_at,
            quality_profile_id: m.quality_profile_id,
            inserted_at: m.inserted_at,
            updated_at: m.updated_at,
        }
    }

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

    fn build_base_cond(kind: &str, monitored: MonitoredFilter, search: Option<&str>) -> Condition {
        let mut cond = Condition::all().add(media_items::Column::Type.eq(kind.to_owned()));
        match monitored {
            MonitoredFilter::All => {}
            MonitoredFilter::Monitored => {
                cond = cond.add(media_items::Column::Monitored.eq(true));
            }
            MonitoredFilter::Unmonitored => {
                cond = cond.add(media_items::Column::Monitored.eq(false));
            }
        }
        if let Some(term) = search {
            let pattern = format!("%{}%", term.to_lowercase());
            cond = cond
                .add(Expr::expr(Func::lower(Expr::col(media_items::Column::Title))).like(pattern));
        }
        cond
    }

    pub async fn count_media(
        db: &DatabaseConnection,
        kind: &str,
        monitored: MonitoredFilter,
        search: Option<&str>,
    ) -> Result<i64, ServerFnError> {
        let cond = build_base_cond(kind, monitored, search);
        let n = media_items::Entity::find()
            .filter(cond)
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("count media: {err}")))?;
        Ok(i64::try_from(n).unwrap_or(i64::MAX))
    }

    pub async fn fetch_media(
        db: &DatabaseConnection,
        kind: &str,
        monitored: MonitoredFilter,
        search: Option<&str>,
        sort: MediaSort,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<MediaItem>, ServerFnError> {
        let cond = build_base_cond(kind, monitored, search);
        let mut q = media_items::Entity::find().filter(cond);
        // Order by — SeaORM's typed builder uses Expr for COLLATE NOCASE
        // → lower(title) parity break (matches graphql repos).
        let lower_title: SimpleExpr = Func::lower(Expr::col(media_items::Column::Title)).into();
        q = match sort {
            MediaSort::TitleAsc => q.order_by(lower_title, Order::Asc),
            MediaSort::TitleDesc => q.order_by(lower_title, Order::Desc),
            MediaSort::YearAsc => q
                .order_by_asc(media_items::Column::Year)
                .order_by(lower_title, Order::Asc),
            MediaSort::YearDesc => q
                .order_by_desc(media_items::Column::Year)
                .order_by(lower_title, Order::Asc),
            MediaSort::AddedAsc => q.order_by_asc(media_items::Column::InsertedAt),
            MediaSort::AddedDesc => q.order_by_desc(media_items::Column::InsertedAt),
        };
        let rows = q
            .offset(u64::from(offset))
            .limit(u64::from(limit))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list media: {err}")))?;
        Ok(rows.into_iter().map(model_to_media_item).collect())
    }

    /// EXISTS subquery against `media_files` for the "available locally"
    /// badge. Movies check the direct `media_item_id` FK; TV shows go
    /// one hop further through `episodes`.
    pub async fn row_has_files(
        db: &DatabaseConnection,
        id: &str,
        kind: &str,
    ) -> Result<bool, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Ok(false);
        };
        let backend = db.get_database_backend();
        if kind == "tv_show" {
            // media_files.episode_id IN (SELECT id FROM episodes WHERE media_item_id = ?)
            let subquery = Query::select()
                .column(episodes::Column::Id)
                .from(episodes::Entity)
                .and_where(
                    Expr::col(episodes::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)),
                )
                .to_owned();
            let count = media_files::Entity::find()
                .filter(Expr::col(media_files::Column::EpisodeId).in_subquery(subquery))
                .filter(media_files::Column::TrashedAt.is_null())
                .count(db)
                .await
                .map_err(|err| ServerFnError::new(format!("has_files: {err}")))?;
            Ok(count > 0)
        } else {
            let count = media_files::Entity::find()
                .filter(
                    Expr::col(media_files::Column::MediaItemId)
                        .eq(wrapper.into_simple_expr(backend)),
                )
                .filter(media_files::Column::TrashedAt.is_null())
                .count(db)
                .await
                .map_err(|err| ServerFnError::new(format!("has_files: {err}")))?;
            Ok(count > 0)
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

    pub async fn fetch_media_detail(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<MediaDetail, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new("Media item not found"));
        };
        let backend = db.get_database_backend();
        let row = media_items::Entity::find()
            .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("detail: {err}")))?
            .ok_or_else(|| ServerFnError::new("Media item not found"))?;
        Ok(into_detail(&model_to_media_item(row)))
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
        db: &DatabaseConnection,
        movie_id: &str,
    ) -> Result<Vec<MediaFileSummary>, ServerFnError> {
        let Some(wrapper) = parse_uuid(movie_id) else {
            return Ok(Vec::new());
        };
        let backend = db.get_database_backend();
        let rows = media_files::Entity::find()
            .filter(
                Expr::col(media_files::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)),
            )
            .filter(media_files::Column::TrashedAt.is_null())
            .order_by_asc(media_files::Column::Path)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("movie files: {err}")))?;
        // Sort by resolution priority in-Rust — the typed builder
        // doesn't compose a CASE ... WHEN cleanly.
        let mut rows = rows;
        rows.sort_by_key(|m| match m.resolution.as_deref() {
            Some("2160p") => 0,
            Some("1080p") => 1,
            Some("720p") => 2,
            Some("480p") => 3,
            _ => 4,
        });
        Ok(rows
            .into_iter()
            .map(|m| {
                let path = m.path.unwrap_or_default();
                let filename = path.rsplit('/').next().unwrap_or(&path).to_owned();
                MediaFileSummary {
                    id: m.id.to_string(),
                    path,
                    filename,
                    resolution: m.resolution,
                    codec: m.codec,
                    audio_codec: m.audio_codec,
                    size: m.size,
                }
            })
            .collect())
    }

    pub async fn fetch_show_seasons(
        db: &DatabaseConnection,
        show_id: &str,
    ) -> Result<Vec<SeasonView>, ServerFnError> {
        let Some(wrapper) = parse_uuid(show_id) else {
            return Ok(Vec::new());
        };
        let backend = db.get_database_backend();
        let episode_rows = episodes::Entity::find()
            .filter(Expr::col(episodes::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)))
            .order_by_asc(episodes::Column::SeasonNumber)
            .order_by_asc(episodes::Column::EpisodeNumber)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("seasons episodes: {err}")))?;

        // Episode IDs that have at least one non-trashed media file.
        let episode_ids: Vec<UuidText> = episode_rows.iter().map(|e| e.id).collect();
        let with_files: std::collections::HashSet<UuidText> = if episode_ids.is_empty() {
            std::collections::HashSet::new()
        } else {
            let rows = media_files::Entity::find()
                .filter(media_files::Column::EpisodeId.is_in(episode_ids))
                .filter(media_files::Column::TrashedAt.is_null())
                .all(db)
                .await
                .map_err(|err| ServerFnError::new(format!("seasons files: {err}")))?;
            rows.into_iter().filter_map(|mf| mf.episode_id).collect()
        };

        let mut seasons: BTreeMap<i32, Vec<EpisodeView>> = BTreeMap::new();
        for e in episode_rows {
            let season_key = e.season_number;
            let has_files = with_files.contains(&e.id);
            let air_date_str = e
                .air_date
                .map(|d| d.format("%Y-%m-%d").to_string())
                .unwrap_or_default();
            seasons.entry(season_key).or_default().push(EpisodeView {
                id: e.id.to_string(),
                season_number: Some(e.season_number),
                episode_number: Some(e.episode_number),
                title: e.title,
                air_date: air_date_str,
                monitored: e.monitored.unwrap_or(false),
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

    // ---------- U25.c: action endpoints ----------

    pub(super) async fn toggle_media_monitored(
        id: &str,
    ) -> Result<MonitorToggleAck, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let next = flip_media_monitored(&st.db, id).await?;
        Ok(MonitorToggleAck { monitored: next })
    }

    pub(super) async fn toggle_episode_monitored(
        id: &str,
    ) -> Result<MonitorToggleAck, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let next = flip_episode_monitored(&st.db, id).await?;
        Ok(MonitorToggleAck { monitored: next })
    }

    pub(super) async fn delete_media(id: &str) -> Result<(), ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        delete_media_item_db_only(&st.db, id).await
    }

    /// Read-then-write to determine the new monitored value. `SQLite`
    /// doesn't have a `RETURNING ...` shape we can rely on in 3.x; we
    /// pay one extra round-trip for symmetry. The race is benign — two
    /// rapid taps cancel each other out, matching the Phoenix
    /// click-debouncing behavior.
    pub async fn flip_media_monitored(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<bool, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new("Media item not found"));
        };
        let backend = db.get_database_backend();
        let row = media_items::Entity::find()
            .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("read monitored: {err}")))?
            .ok_or_else(|| ServerFnError::new("Media item not found"))?;
        let next = !row.monitored.unwrap_or(false);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let res = media_items::Entity::update_many()
            .col_expr(media_items::Column::Monitored, Expr::value(next))
            .col_expr(
                media_items::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("flip media monitored: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new("Media item not found"));
        }
        Ok(next)
    }

    pub async fn flip_episode_monitored(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<bool, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new("Episode not found"));
        };
        let backend = db.get_database_backend();
        let row = episodes::Entity::find()
            .filter(Expr::col(episodes::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("read episode monitored: {err}")))?
            .ok_or_else(|| ServerFnError::new("Episode not found"))?;
        let next = !row.monitored.unwrap_or(false);
        let now = DateTimeSecs::from(chrono::Utc::now());
        episodes::Entity::update_many()
            .col_expr(episodes::Column::Monitored, Expr::value(next))
            .col_expr(episodes::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(episodes::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("flip episode: {err}")))?;
        Ok(next)
    }

    /// DB-only delete. The Phoenix flow optionally also deletes the
    /// on-disk files via `Library.delete_files`; that's deferred to
    /// a later commit because it requires the file-deletion worker
    /// path to be ported and dry-run tested first. Files remain on
    /// disk; the operator can rescan to re-import.
    ///
    /// We delete child rows explicitly rather than relying on
    /// `ON DELETE CASCADE` because the Phoenix schema doesn't always
    /// declare cascade — Ecto handles the cascade in Elixir code
    /// (`Mydia.Media.delete_media_item`), so the DB constraints are a
    /// mix. Explicit deletes are safe regardless of cascade state.
    pub async fn delete_media_item_db_only(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<(), ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new("Media item not found"));
        };
        let backend = db.get_database_backend();
        // We don't have a SeaORM transaction here; do the three deletes
        // in order. If any fails, partial progress is acceptable because
        // the Phoenix cleanup also runs idempotently.
        // Files first — both direct media_item_id refs and via episodes.
        let episode_ids_subq = Query::select()
            .column(episodes::Column::Id)
            .from(episodes::Entity)
            .and_where(
                Expr::col(episodes::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)),
            )
            .to_owned();
        media_files::Entity::delete_many()
            .filter(
                Condition::any()
                    .add(
                        Expr::col(media_files::Column::MediaItemId)
                            .eq(wrapper.into_simple_expr(backend)),
                    )
                    .add(Expr::col(media_files::Column::EpisodeId).in_subquery(episode_ids_subq)),
            )
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete media files: {err}")))?;
        episodes::Entity::delete_many()
            .filter(Expr::col(episodes::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete episodes: {err}")))?;
        let res = media_items::Entity::delete_many()
            .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete media item: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new("Media item not found"));
        }
        Ok(())
    }
}
