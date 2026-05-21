//! Search resolver — port of
//! `lib/mydia_web/schema/resolvers/search_resolver.ex`.
//!
//! The Phoenix resolver:
//!
//! 1. Empty queries fall through to `{:ok, %{results: [], total_count: 0}}`.
//! 2. Otherwise `Mydia.Media.list_media_items(search: query)` is
//!    called with an optional `:type` filter derived from the
//!    `:types` arg.
//! 3. Results are truncated to `first` (default 20), wrapped in the
//!    `:search_result` shape with `score: nil` and per-row artwork
//!    pulled from `metadata.poster_path` / `metadata.backdrop_path`.
//!
//! The Rust port keeps the simple LIKE matching for U11; an actual
//! ranker lands when U21 (indexers + search scorer) brings the
//! ranking logic online.

use async_graphql::{Context, Object, ID};

use crate::context::GraphqlAppState;
use crate::node_id::{NodeId, NodeRef};
use crate::repos::media;
use crate::types::{Artwork, MediaType, SearchResult, SearchResults};

const DEFAULT_FIRST: i32 = 20;
const MAX_FIRST: i32 = 200;

#[derive(Default)]
pub struct SearchQueries;

#[Object]
impl SearchQueries {
    /// Substring search across media item titles.
    async fn search(
        &self,
        ctx: &Context<'_>,
        query: String,
        #[graphql(default = 20)] first: i32,
        types: Option<Vec<MediaType>>,
    ) -> async_graphql::Result<SearchResults> {
        if query.is_empty() {
            return Ok(SearchResults {
                results: Vec::new(),
                total_count: 0,
            });
        }
        let state = ctx.data::<GraphqlAppState>()?;
        let kind = type_filter_to_db(types.as_ref());
        let limit = first.clamp(0, MAX_FIRST) as usize;

        let opts = media::ListMediaItemsOpts {
            kind,
            category: None,
            has_files: false,
            added_since: None,
            search: Some(&query),
        };
        let rows = media::list_media_items(&state.db, &opts).await?;

        let results: Vec<SearchResult> = rows.iter().take(limit).map(build_search_result).collect();
        let total_count = results.len() as i32;

        // DEFAULT_FIRST is the documented Phoenix default (`Map.get(args, :first, 20)`);
        // referenced from docs above so the constant is touched.
        let _ = DEFAULT_FIRST;

        Ok(SearchResults {
            results,
            total_count,
        })
    }
}

/// Mirror of `lib/mydia_web/schema/resolvers/search_resolver.ex:18-32`:
/// when `:types` is `nil` or `[]`, no filter. Mixing `movie` and
/// `tv_show` also yields no filter. A single-kind list narrows to that
/// kind.
fn type_filter_to_db(types: Option<&Vec<MediaType>>) -> Option<&'static str> {
    let types = types?;
    if types.is_empty() {
        return None;
    }
    let has_movie = types.contains(&MediaType::Movie);
    let has_tv = types.contains(&MediaType::TvShow);
    match (has_movie, has_tv) {
        (true, false) => Some("movie"),
        (false, true) => Some("tv_show"),
        (true, true) | (false, false) => None,
    }
}

fn build_search_result(row: &mydia_rs_models::MediaItem) -> SearchResult {
    let type_ = row
        .r#type
        .as_deref()
        .and_then(MediaType::from_db_str)
        .unwrap_or(MediaType::Movie);
    let id = match row.r#type.as_deref() {
        Some("tv_show") => NodeId::TvShow(NodeRef::Str(row.id.0.to_string())).encode(),
        Some("episode") => NodeId::Episode(NodeRef::Str(row.id.0.to_string())).encode(),
        _ => NodeId::Movie(NodeRef::Str(row.id.0.to_string())).encode(),
    };
    SearchResult {
        id: ID(id),
        type_,
        title: row.title.clone().unwrap_or_default(),
        year: row.year,
        artwork: build_artwork(row),
        score: None,
    }
}

fn build_artwork(row: &mydia_rs_models::MediaItem) -> Option<Artwork> {
    let metadata = row.metadata.as_ref()?;
    let poster_path = metadata
        .0
        .get("poster_path")
        .and_then(|v| v.as_str())
        .map(std::borrow::ToOwned::to_owned);
    let backdrop_path = metadata
        .0
        .get("backdrop_path")
        .and_then(|v| v.as_str())
        .map(std::borrow::ToOwned::to_owned);
    if poster_path.is_none() && backdrop_path.is_none() {
        return None;
    }
    Some(Artwork {
        // Search results carry raw metadata paths (same shape as
        // discovery's U10.b placeholder); the metadata-relay-aware
        // URLs come online with the metadata client port (U18).
        poster_url: poster_path,
        backdrop_url: backdrop_path,
        thumbnail_url: None,
    })
}
