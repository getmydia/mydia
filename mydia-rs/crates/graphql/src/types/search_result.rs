//! Search result types — port of
//! `lib/mydia_web/schema/common_types.ex:76-90` (`:search_result` and
//! `:search_results`).
//!
//! The Phoenix resolver returns `SearchResults { results, total_count }`
//! where `total_count = length(results)` — pre-pagination filtering
//! isn't surfaced. The Rust port matches.

use async_graphql::{SimpleObject, ID};

use crate::types::{Artwork, MediaType};

/// One row in a search response. `score` is `None` from this resolver
/// (Phoenix leaves it `nil`) and is reserved for a future ranking-
/// aware port that consumes the indexer-side scorer in U21.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SearchResult")]
pub struct SearchResult {
    pub id: ID,
    #[graphql(name = "type")]
    pub type_: MediaType,
    pub title: String,
    pub year: Option<i32>,
    pub artwork: Option<Artwork>,
    pub score: Option<f64>,
}

/// Container envelope for search responses.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SearchResults")]
pub struct SearchResults {
    pub results: Vec<SearchResult>,
    pub total_count: i32,
}
