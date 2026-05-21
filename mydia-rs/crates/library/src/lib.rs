//! Library scanning, release-name parsing, file grouping, metadata
//! enrichment, and file analysis.
//!
//! This crate is the Rust port of `lib/mydia/library/`. It lands in
//! U16 — the workers that consume these building blocks live in U17.
//!
//! ## Modules
//!
//! - [`scanner`] — recursive directory traversal that finds video
//!   files and reports progress through the `library_scanner`
//!   `PubSub` topic. Port of `lib/mydia/library/scanner.ex`.
//! - [`release_parser`] — release-name parser. Multi-stage pipeline
//!   (tokenize -> classify -> resolve -> extract quality). Port of
//!   `lib/mydia/library/release_parser/`.
//! - [`file_parser`] — thin facade over the release parser, matching
//!   the call sites that just need a `ParsedFileInfo` from a path.
//! - [`file_grouper`] — groups parsed releases into media-item
//!   candidates suitable for the import workflow UI.
//! - [`metadata_enricher`] — orchestrates [`Provider`] calls against
//!   the metadata-relay to fetch full metadata for a matched media
//!   item.
//! - [`file_analyzer`] — ffprobe-driven analysis of a single media
//!   file, returning resolution / codec / duration / bitrate. Uses
//!   `tokio::process::Command` with `kill_on_drop(true)` and a 30s
//!   `tokio::time::timeout` so cancelled or hung probes do not leak
//!   processes.
//!
//! ## Scope boundary
//!
//! Workers (apalis jobs) live in U17. This crate produces the
//! building blocks; the `LibraryScanner` / `FileAnalysis` /
//! `MediaImport` workers wire them together.
//!
//! [`Provider`]: mydia_rs_metadata::Provider

pub mod error;
pub mod file_analyzer;
pub mod file_grouper;
pub mod file_parser;
pub mod metadata_enricher;
pub mod release_parser;
pub mod scanner;

pub use error::LibraryError;
pub use file_analyzer::{AnalysisOutcome, FileAnalysis, FileAnalyzer};
pub use file_grouper::{
    FileGrouper, GroupedEpisode, GroupedFile, GroupedSeason, GroupedSeries, GroupedSummary,
};
pub use file_parser::FileParser;
pub use metadata_enricher::{EnrichInput, MetadataEnricher};
pub use release_parser::{MediaKind, ParsedFileInfo, Quality, ReleaseParser};
pub use scanner::{ScanFile, ScanOptions, ScanProgressEvent, ScanResult, Scanner};
