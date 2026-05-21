// Per-crate clippy allow-list. The `doc_markdown` lint flags
// well-known proper nouns (`FlareSolverr`, `OpenSubtitles`, …) that are
// intentionally written without backticks where they appear as plain
// English prose. The other allows cover patterns common in port-from-
// Elixir code where rewrites would add noise without making the
// intent clearer.
#![allow(
    clippy::doc_markdown,
    clippy::map_unwrap_or,
    clippy::match_same_arms,
    clippy::format_push_string
)]

//! Indexer engine for mydia-rs.
//!
//! Port of `lib/mydia/indexers/` (Cardigann v11 engine, release
//! ranker, search scorer, quality parser, adapter trait, registry,
//! rate limiter, health cache, `FlareSolverr` client). Consumed by:
//!
//! - **`crates/jobs/` (U17)** — `MovieSearch`, `TvShowSearch`,
//!   `IndexerDefinitionSync` workers register adapters with the
//!   [`registry::IndexerRegistry`] and feed search results through
//!   [`release_ranker::rank_all`].
//! - **`crates/graphql/`** — admin indexer pages call into the
//!   adapter registry for `testConnection` and `getCapabilities`.
//!
//! ## Module map
//!
//! - [`adapter`] — `IndexerAdapter` trait + shared config/options shapes.
//! - [`cardigann`] — Cardigann v11 engine submodules.
//! - [`category_mapping`] — Torznab category constants + helpers.
//! - [`error`] — `IndexerError` and `ErrorKind`.
//! - [`feature_flags`] — `ENABLE_CARDIGANN` resolution.
//! - [`flaresolverr`] — FlareSolverr HTTP client.
//! - [`health`] — Health status types + TTL cache.
//! - [`quality_parser`] — Release-title quality extraction.
//! - [`rate_limiter`] — Per-indexer sliding-window limiter.
//! - [`registry`] — `IndexerRegistry` (adapter + config lookup).
//! - [`release_ranker`] — Filtering + ranking pipeline.
//! - [`search_result`] — Normalized `SearchResult` struct.
//! - [`search_scorer`] — Unified scoring (used by ranker + UI).

pub mod adapter;
pub mod cardigann;
pub mod category_mapping;
pub mod error;
pub mod feature_flags;
pub mod flaresolverr;
pub mod health;
pub mod quality_parser;
pub mod rate_limiter;
pub mod registry;
pub mod release_ranker;
pub mod search_result;
pub mod search_scorer;

pub use adapter::{
    AdapterConfig, AdapterKind, Capabilities, ConnectionInfo, IndexerAdapter, SearchOpts,
};
pub use error::{ErrorKind, IndexerError};
pub use registry::IndexerRegistry;
pub use search_result::{
    DownloadProtocol, QualityInfo, RankedResult, ScoreBreakdown, SearchResult, SearchResultBuilder,
    SearchResultMetadata,
};
