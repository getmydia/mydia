//! `DownloadClient` async trait. Rust port of
//! `lib/mydia/downloads/client.ex`.
//!
//! Phoenix exposes the adapter behaviour as `@callback` functions on
//! the `Mydia.Downloads.Client` behaviour, with each implementation a
//! plain module. The Rust port uses `#[async_trait::async_trait]`
//! because [`ClientRegistry`](crate::registry::ClientRegistry) stores
//! adapters as `Arc<dyn DownloadClient>` — and `async fn` in traits
//! is not dyn-compatible without the macro.
//!
//! ## Method shape
//!
//! The original Phoenix surface has eight callbacks
//! (`test_connection`, `add_torrent`, `get_status`, `list_torrents`,
//! `remove_torrent`, `pause_torrent`, `resume_torrent`,
//! `supported_protocols`). The Rust port collapses the
//! protocol-specific `add_torrent` / `add_nzb` distinction at the trait
//! level via [`Protocol`] + a single [`Self::add`] method that takes
//! the typed [`TorrentInput`] enum, matching how the resolver layer
//! (U33) actually calls into the adapters. Adapters reject the
//! protocols they don't support via the [`Self::supported_protocols`]
//! method, which the registry consults before dispatch.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::collections::HashMap;

use crate::error::DownloadError;

/// Download protocol an adapter can accept. Torrent-capable clients
/// (qBittorrent, Transmission, rTorrent, blackhole, debrid) list
/// [`Self::Torrent`]; Usenet-capable clients (`SABnzbd`, `NZBGet`) list
/// [`Self::Nzb`]. Adapters that accept either kind return both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Protocol {
    Torrent,
    Nzb,
}

/// Tagged-union input accepted by [`DownloadClient::add`]. Matches the
/// Phoenix `{:magnet, _} | {:file, _} | {:url, _}` tuples used by
/// `lib/mydia/downloads/client.ex`.
#[derive(Debug, Clone)]
pub enum TorrentInput {
    /// `magnet:?xt=...` URI. The most common shape.
    Magnet(String),
    /// Raw `.torrent` / `.nzb` bytes plus an optional release title to
    /// preserve in the upload filename (some clients display it
    /// verbatim in the UI).
    File {
        bytes: Vec<u8>,
        title: Option<String>,
    },
    /// HTTP(S) URL the client can download the payload from. Mostly
    /// used by indexer-driven flows where the indexer hands us a
    /// `.torrent` URL rather than a magnet.
    Url(String),
}

/// Connection details + adapter-specific options. The map-shaped
/// `options` field stays loosely-typed to mirror the Phoenix
/// `connection_settings` JSON column — every adapter has its own keys
/// it pulls from there (`rpc_path`, `url_base`, `watch_folder`, ...).
#[derive(Debug, Clone, Default)]
pub struct ClientConfig {
    pub host: String,
    pub port: u16,
    pub use_ssl: bool,
    pub username: Option<String>,
    pub password: Option<String>,
    pub api_key: Option<String>,
    pub url_base: Option<String>,
    pub options: HashMap<String, String>,
}

impl ClientConfig {
    /// Build a `http(s)://host[:port][/url_base]` base URL. Adapters
    /// append their own path suffix on top.
    #[must_use]
    pub fn base_url(&self) -> String {
        let scheme = if self.use_ssl { "https" } else { "http" };
        let host = if self.host.is_empty() {
            "localhost"
        } else {
            self.host.as_str()
        };
        let port = if self.port == 0 {
            String::new()
        } else {
            format!(":{}", self.port)
        };
        let base = self.url_base.as_deref().unwrap_or("");
        format!("{scheme}://{host}{port}{base}")
    }

    /// Lookup a string-typed option, falling back to `default`.
    pub fn option(&self, key: &str, default: &str) -> String {
        self.options
            .get(key)
            .cloned()
            .unwrap_or_else(|| default.to_owned())
    }
}

/// Adapter metadata returned by `test_connection`. Carried into the
/// admin `LiveView` verbatim in Phoenix; the Rust port keeps the same
/// fields so the wire shape is unchanged during the parallel window.
#[derive(Debug, Clone, Default)]
pub struct ClientInfo {
    pub version: String,
    pub api_version: Option<String>,
    pub rpc_version: Option<String>,
}

/// Internal download state. Mirrors Phoenix's
/// `Mydia.Downloads.Structs.DownloadStatus.state` atom set so the
/// orchestrator (U17) can pattern-match without translating.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadState {
    Downloading,
    Seeding,
    Paused,
    Error,
    Completed,
    Checking,
}

/// Per-download status snapshot. Direct port of
/// `Mydia.Downloads.Structs.DownloadStatus`. The numeric fields are
/// `Option<u64>` rather than the Phoenix `0`-default pattern because
/// "we didn't observe this counter" is materially different from
/// "the counter is zero" for the U17 stall detector.
#[derive(Debug, Clone)]
pub struct DownloadStatus {
    pub id: String,
    pub name: String,
    pub state: DownloadState,
    pub progress: f64,
    pub download_speed: u64,
    pub upload_speed: u64,
    pub downloaded: u64,
    pub uploaded: u64,
    pub size: u64,
    pub eta: Option<u64>,
    pub ratio: f64,
    pub save_path: String,
    pub added_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
}

impl DownloadStatus {
    /// Build a minimally-populated status. Used by adapters that don't
    /// observe every counter on every call (blackhole, for instance).
    #[must_use]
    pub fn skeletal(id: String, name: String, state: DownloadState) -> Self {
        Self {
            id,
            name,
            state,
            progress: 0.0,
            download_speed: 0,
            upload_speed: 0,
            downloaded: 0,
            uploaded: 0,
            size: 0,
            eta: None,
            ratio: 0.0,
            save_path: String::new(),
            added_at: None,
            completed_at: None,
        }
    }
}

/// Options accepted by [`DownloadClient::add`]. Matches Phoenix's
/// keyword-list shape so the call sites in U33 can pass through
/// admin-supplied values without translation.
#[derive(Debug, Clone, Default)]
pub struct AddOpts {
    pub category: Option<String>,
    pub tags: Vec<String>,
    pub save_path: Option<String>,
    pub paused: Option<bool>,
    pub title: Option<String>,
}

/// Options accepted by [`DownloadClient::list_active`]. Equivalent to
/// Phoenix's `list_torrents_opts`; the `downloads` map exists for the
/// debrid adapter's R8 metadata lookup but other adapters ignore it.
#[derive(Debug, Clone, Default)]
pub struct ListOpts {
    pub filter_state: Option<DownloadState>,
    pub category: Option<String>,
    pub tag: Option<String>,
}

/// Adapter contract. Each per-client module under [`crate::clients`]
/// implements this trait. The registry holds them as
/// `Arc<dyn DownloadClient>` so they can be looked up by name at
/// runtime — `#[async_trait]` because async fn in traits isn't yet
/// dyn-compatible without it.
#[async_trait]
pub trait DownloadClient: Send + Sync + 'static {
    /// Adapter identifier used in logs, metrics, and the client-row
    /// `client_type` column. Returns a static string per adapter.
    fn name(&self) -> &'static str;

    /// Which protocols this adapter can ingest. The orchestrator (U17)
    /// uses this to filter eligible clients for a given indexer
    /// release.
    fn supported_protocols(&self) -> &'static [Protocol];

    /// Verify connectivity + credentials against the remote client.
    /// Returns a [`ClientInfo`] payload on success that the admin UI
    /// surfaces verbatim.
    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError>;

    /// Add a download. The `input` carries the payload shape; the
    /// adapter is responsible for rejecting unsupported variants
    /// (e.g. `SABnzbd` rejects [`TorrentInput::Magnet`]).
    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError>;

    /// Convenience wrapper for the torrent-only path. Default
    /// implementation just calls [`Self::add`].
    async fn add_torrent(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        self.add(config, input, opts).await
    }

    /// Convenience wrapper for the NZB path. Default implementation
    /// just calls [`Self::add`].
    async fn add_nzb(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        self.add(config, input, opts).await
    }

    /// Snapshot of all downloads currently visible to the remote
    /// client. The U17 `DownloadMonitor` cron worker drives this on
    /// every tick.
    async fn list_active(
        &self,
        config: &ClientConfig,
        opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError>;

    /// Remove / cancel a download by its client-side id. If
    /// `delete_files` is true, also instruct the remote to delete the
    /// downloaded bytes (matches Phoenix's `:delete_files` opt).
    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        delete_files: bool,
    ) -> Result<(), DownloadError>;

    /// List the files belonging to a completed download. Used by the
    /// U17 importer to walk the bytes that arrived.
    async fn get_files(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<Vec<String>, DownloadError>;

    /// Resolve the on-disk path the remote client wrote the download
    /// to. Equivalent to `status.save_path`; exposed as its own method
    /// because some adapters can answer it cheaper than running a
    /// full `get_status`.
    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError>;
}
