// Per-crate clippy allow-list. The `doc_markdown` lint flags
// well-known proper nouns (`OpenSubtitles`, …) that read fine without
// backticks. `format_push_string` and `map_unwrap_or` are recurring
// patterns in port-from-Elixir code where rewrites add noise without
// making the intent clearer.
#![allow(
    clippy::doc_markdown,
    clippy::format_push_string,
    clippy::map_unwrap_or
)]

//! Subtitle provider system for mydia-rs.
//!
//! Port of `lib/mydia/subtitles/`. Consumed by:
//!
//! - **`crates/jobs/` (U17)** — `SubtitleDownloader`,
//!   `MovieDownloadSubtitles`, `EpisodeDownloadSubtitles` workers wrap
//!   `Arc<dyn SubtitleProvider>` and persist results via the `db` crate.
//! - **`crates/graphql/`** — admin subtitle pages call into
//!   `MetadataRelay::validate_config` for the relay-mode setup flow.
//!
//! ## Module map
//!
//! - [`downloader`] — Provider-agnostic download pipeline + hash check.
//! - [`error`] — `SubtitleError` taxonomy.
//! - [`extractor`] — ffprobe / ffmpeg embedded-track extraction.
//! - [`feature_flags`] — `SUBTITLE_FEATURE_ENABLED` resolution.
//! - [`hash`] — `OpenSubtitles` `moviehash` algorithm.
//! - [`metadata_relay`] — HTTP client for the metadata-relay subtitle endpoints.
//! - [`provider`] — `SubtitleProvider` trait + `ProviderConfig`.
//! - [`structs`] — `QuotaInfo`, `SubtitleSearchResult`, etc.

pub mod downloader;
pub mod error;
pub mod extractor;
pub mod feature_flags;
pub mod hash;
pub mod metadata_relay;
pub mod provider;
pub mod structs;

pub use error::{SubtitleError, SubtitleErrorKind};
pub use metadata_relay::MetadataRelay;
pub use provider::{ProviderConfig, SubtitleProvider, SubtitleRef};
pub use structs::{
    ProviderKind, QuotaInfo, QuotaType, SearchParams, SubtitleRecord, SubtitleSearchResult,
};
