//! metadata-relay HTTP client, provider trait, and registry.
//!
//! This crate is the Rust port of `lib/mydia/metadata/`. It is the
//! single HTTP boundary for fetching media metadata (TMDB, TVDB,
//! Open Library, `MusicBrainz` / Cover Art Archive) through the
//! self-hosted metadata-relay service.
//!
//! ## Consumers
//!
//! - **`crates/graphql/`** — search and detail resolvers (`browse`,
//!   `discovery`, `media_fields`) call into [`relay::Relay`] /
//!   [`open_library::OpenLibrary`] via a [`registry::ProviderRegistry`]
//!   built at boot.
//! - **`crates/jobs/` (U17)** — `MovieMetadataRefresh`,
//!   `TvShowMetadataRefresh`, and similar background workers consume
//!   the same trait. The trait being async fn dyn-compatible (via
//!   `async_trait`) lets the worker layer take `Arc<dyn Provider>`.
//!
//! ## Design notes
//!
//! - **Errors mirror Elixir.** [`error::MetadataError`] carries the
//!   same atom-keyed taxonomy as `Mydia.Metadata.Provider.Error` and
//!   the enum serializes to `snake_case` so the wire shapes line up
//!   during U34's compatibility window.
//! - **Atoms become enums.** `MediaType` and `ProviderKind` derive
//!   `Serialize` / `Deserialize` with `rename_all = "snake_case"`,
//!   so `MediaType::TvShow` ↔ `"tv_show"` matches
//!   `Atom.to_string(:tv_show)`.
//! - **`Provider` is `async_trait`-shaped.** Stable async fn in traits
//!   (Rust 1.75+) is **not** dyn-compatible without explicit return
//!   types; since the registry stores `Arc<dyn Provider>`, the
//!   `async_trait` macro is the path that keeps the call sites
//!   readable.
//!
//! ## Quick example
//!
//! ```no_run
//! use mydia_rs_metadata::{
//!     provider::{Provider, ProviderConfig, SearchOpts},
//!     relay::Relay,
//!     structs::MediaType,
//! };
//!
//! # async fn example() -> Result<(), mydia_rs_metadata::error::MetadataError> {
//! let config = ProviderConfig::metadata_relay_default();
//! let relay = Relay::new();
//! let opts = SearchOpts { media_type: Some(MediaType::Movie), ..Default::default() };
//! let results = relay.search(&config, "The Matrix", &opts).await?;
//! println!("{} results", results.len());
//! # Ok(()) }
//! ```

pub mod error;
pub mod http;
pub mod music_relay;
pub mod open_library;
pub mod provider;
pub mod registry;
pub mod relay;
pub mod structs;

pub use error::{ErrorKind, MetadataError};
pub use music_relay::MusicRelay;
pub use open_library::OpenLibrary;
pub use provider::{
    FetchOpts, ImageOpts, Provider, ProviderConfig, SearchOpts, SeasonOpts, TrendingOpts,
};
pub use registry::{ProviderRegistry, RegisteredProvider};
pub use relay::Relay;
pub use structs::{
    BookMetadata, CastMember, ConnectionInfo, CrewMember, EpisodeData, ImageData, ImagesResponse,
    MediaMetadata, MediaType, ProviderKind, SearchResult, SeasonData, SeasonInfo, Video,
};
