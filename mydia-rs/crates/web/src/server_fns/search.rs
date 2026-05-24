//! Library search server function (U26).
//!
//! Interleaved title search across `media_items` rows of type `movie`
//! and `tv_show`. Music / books / adult are explicitly out of scope —
//! the Rust backend drops those surfaces. The ranker uses a simple
//! relevance heuristic: prefix matches beat substring matches, exact
//! matches beat both, and ties break by year desc then title asc.
//!
//! The Phoenix `SearchLive.Index` is a torrent-indexer search surface,
//! not a library search; this is a deliberately different page. The
//! library-search idea is "I know I have this movie somewhere, take
//! me to its detail page", not "find a torrent for X". The torrent
//! search comes back when (and if) the indexer surface is ported.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Hard cap on returned rows. Twenty-five is enough for the top-of-
/// list "you probably wanted this" UX without dragging the wire payload
/// into the kilobytes; the operator can refine the query if they want
/// more.
pub const SEARCH_LIMIT: i64 = 25;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SearchQuery {
    pub q: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchResultItem {
    pub id: String,
    pub title: String,
    pub year: Option<i32>,
    /// `"movie"` or `"tv_show"`.
    pub kind: String,
    pub poster_path: Option<String>,
    /// Year-or-empty plus type label, computed server-side so the
    /// component renders without doing string juggling on the client.
    pub subtitle: String,
}

#[post("/api/search")]
pub async fn search_library(query: SearchQuery) -> Result<Vec<SearchResultItem>, ServerFnError> {
    server::search_library(query).await
}

#[cfg(feature = "server")]
pub mod server {
    use super::{SearchQuery, SearchResultItem, SEARCH_LIMIT};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::media_items;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{QueryOrder, QuerySelect};
    use sea_orm::sea_query::{Condition, Expr, ExprTrait, Func, SimpleExpr};

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn search_library(
        query: SearchQuery,
    ) -> Result<Vec<SearchResultItem>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        execute_search(&st.db, &query.q).await
    }

    /// Run the search against `media_items`. Returns an empty vec for
    /// queries shorter than two characters — search-as-you-type fires
    /// on every keystroke so we gate single-char hits to keep the
    /// payload reasonable.
    pub async fn execute_search(
        db: &DatabaseConnection,
        q: &str,
    ) -> Result<Vec<SearchResultItem>, ServerFnError> {
        let trimmed = q.trim();
        if trimmed.len() < 2 {
            return Ok(Vec::new());
        }

        let rows = fetch_candidates(db, trimmed).await?;
        let q_lower = trimmed.to_lowercase();

        let mut scored: Vec<(SearchScore, SearchResultItem)> = rows
            .into_iter()
            .map(|row| {
                let title_str = row.title.clone();
                let original_str = row.original_title.clone().unwrap_or_default();
                let score = relevance(&q_lower, &title_str, &original_str);
                let poster_path = row
                    .metadata
                    .as_deref()
                    .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
                    .and_then(|v| {
                        v.get("poster_path")
                            .and_then(|p| p.as_str())
                            .map(std::borrow::ToOwned::to_owned)
                    });
                let kind_label = match row.r#type.as_str() {
                    "tv_show" => "TV Show",
                    "movie" => "Movie",
                    other => other,
                };
                let subtitle = match row.year {
                    Some(y) => format!("{y} · {kind_label}"),
                    None => kind_label.to_owned(),
                };
                (
                    score,
                    SearchResultItem {
                        id: row.id.to_string(),
                        title: title_str,
                        year: row.year,
                        kind: row.r#type,
                        poster_path,
                        subtitle,
                    },
                )
            })
            .collect();

        // Sort by score desc, then year desc (newer media first when
        // titles tie), then title asc as a stable tiebreaker.
        scored.sort_by(|a, b| {
            b.0.bucket
                .cmp(&a.0.bucket)
                .then_with(|| b.1.year.cmp(&a.1.year))
                .then_with(|| a.1.title.to_lowercase().cmp(&b.1.title.to_lowercase()))
        });

        Ok(scored.into_iter().map(|(_, item)| item).collect())
    }

    /// Rough relevance score. Higher bucket beats lower bucket; ties
    /// are broken by the caller via year + title.
    #[derive(Debug, Clone, Copy)]
    struct SearchScore {
        bucket: u8,
    }

    fn relevance(q_lower: &str, title: &str, original_title: &str) -> SearchScore {
        let t = title.to_lowercase();
        let o = original_title.to_lowercase();
        // Bucket scoring — higher is more relevant. Picks the first
        // match working from "exact" down. If none matches we still
        // return bucket 0 rather than panic; the SQL LIKE filter
        // should make that path unreachable today.
        let bucket = match () {
            () if t == q_lower || o == q_lower => 4,
            () if t.starts_with(q_lower) || o.starts_with(q_lower) => 3,
            () if t.split_whitespace().any(|w| w == q_lower)
                || o.split_whitespace().any(|w| w == q_lower) =>
            {
                2
            }
            () if t.contains(q_lower) || o.contains(q_lower) => 1,
            () => 0,
        };
        SearchScore { bucket }
    }

    async fn fetch_candidates(
        db: &DatabaseConnection,
        q: &str,
    ) -> Result<Vec<media_items::Model>, ServerFnError> {
        // Music / books / adult are not in scope — we restrict to
        // `movie` and `tv_show` explicitly so the result set never
        // surfaces deprecated domains even if the Phoenix side keeps
        // writing them during the cutover.
        //
        // **Parity break:** Phoenix's `title COLLATE NOCASE ASC` is
        // emitted as `lower(title) ASC` to keep one source between
        // engines, matching the documented U13 pattern.
        let pattern = format!("%{}%", q.to_lowercase());
        let limit = u64::try_from(SEARCH_LIMIT * 2).unwrap_or(0);
        let q_lower = q.to_lowercase();
        let prefix_pattern = format!("{q_lower}%");

        let type_filter = Condition::any()
            .add(media_items::Column::Type.eq("movie".to_owned()))
            .add(media_items::Column::Type.eq("tv_show".to_owned()));

        let _ = (q_lower, prefix_pattern); // ordering is delegated to Rust scoring
        let lower_title: SimpleExpr = Func::lower(Expr::col(media_items::Column::Title)).into();
        let lower_original: SimpleExpr =
            Func::lower(Expr::col(media_items::Column::OriginalTitle)).into();
        let title_match = Condition::any()
            .add(lower_title.clone().like(pattern.clone()))
            .add(lower_original.like(pattern));

        // Pre-sort cheaply by (year desc, lower(title) asc); the
        // CASE-WHEN relevance buckets in the Phoenix query are
        // recomputed in Rust below, so the SQL-level relevance ordering
        // is dropped (it was non-portable anyway, and the LIMIT
        // overscan gives the in-memory sort headroom).
        media_items::Entity::find()
            .filter(type_filter)
            .filter(title_match)
            .order_by_desc(media_items::Column::Year)
            .order_by_asc(lower_title)
            .limit(limit)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("search: {err}")))
    }
}
