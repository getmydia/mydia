//! Download client adapters, MP4 transcoding, torrent matching, and the
//! release blacklist. Rust port of `lib/mydia/downloads/`.
//!
//! ## Crate shape
//!
//! Phoenix's `Mydia.Downloads` namespace covers ~15.1k LOC across 45 files
//! spanning seven download-client adapters (qBittorrent, Transmission,
//! rTorrent, `SABnzbd`, `NZBGet`, blackhole, debrid), an `FFmpeg` MP4
//! progressive transcoder (separate from U19's HLS transcoder), a
//! transcode job manager, torrent matching, and the release blacklist.
//!
//! The Rust port keeps the layering intact but flattens the OTP
//! supervision tree into:
//!
//! - [`adapter::DownloadClient`] — async trait every per-client module
//!   implements (`add_torrent`, `add_nzb`, `list_active`, `cancel`,
//!   `get_files`, `get_save_path`).
//! - [`registry::ClientRegistry`] — owns the `Arc<dyn DownloadClient>`
//!   instances. Indexed by client name; populated at boot by U17.
//! - [`clients`] — per-adapter implementations. Each module is
//!   responsible for talking to one external client API.
//! - [`transcoder::Transcoder`] — `tokio::process::Command` wrapper that
//!   runs the progressive-MP4 `ffmpeg` invocation.
//! - [`job_manager::JobManager`] — concurrent transcode-job registry
//!   backed by `dashmap` plus `tokio::sync::oneshot` cancellation
//!   handles.
//! - [`torrent_matcher`] — title + year scoring of parsed torrent
//!   releases against library items.
//! - [`blacklist::Blacklist`] — exact-match `(indexer, guid)` rejection
//!   store. Persists via [`mydia_rs_db`] in production; ships an
//!   in-memory `MemoryStore` for tests and dev.
//!
//! ## Scope boundary
//!
//! - **No `apalis` workers here.** `DownloadMonitor` (the cron worker
//!   that polls every adapter for live state) belongs to U17.
//! - **No HTTP routes here.** The axum mount for download admin /
//!   playback control endpoints lives in U33.
//! - **No DB writes through this crate yet.** The persistence layer
//!   (download rows, transcode job rows) is wired in U17; this crate
//!   exposes pure-API-call adapters and an in-memory job tracker so
//!   U17 can plug DB calls in without reshaping the surface area.

pub mod adapter;
pub mod blacklist;
pub mod clients;
pub mod error;
pub mod job_manager;
pub mod registry;
pub mod service;
pub mod torrent_matcher;
pub mod transcoder;

pub use adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
pub use blacklist::{Blacklist, BlacklistEntry, MemoryStore as MemoryBlacklistStore};
pub use error::DownloadError;
pub use job_manager::{JobManager, JobStatus, TranscodeJobHandle};
pub use registry::ClientRegistry;
pub use service::{
    DownloadService, Job, JobInfo, MediaFileRow, QualityOption, ServiceConfig, ServiceError,
};
pub use torrent_matcher::{MatchResult, TorrentMatcher};
pub use transcoder::{Resolution, TranscodeOptions, Transcoder};
