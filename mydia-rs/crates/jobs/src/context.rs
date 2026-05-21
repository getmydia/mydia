//! Shared resources injected into apalis workers via the `Data`
//! extractor.
//!
//! Phoenix workers reach for `Mydia.Repo`, `Phoenix.PubSub`, the various
//! supervised registries, and `Application.get_env` at execution time.
//! mydia-rs collects the equivalent handles in [`AppContext`] and the
//! supervision tree clones one into every worker via
//! `WorkerBuilder::data(...)`.
//!
//! Every field is `Clone`-cheap (an `Arc` or a `Pubsub` newtype that
//! wraps `Arc<Inner>`). Worker code calls e.g. `ctx.pubsub.publish(...)`
//! or `&ctx.db` without taking ownership; the per-job clone is cheap.

use std::sync::Arc;

use mydia_rs_db::Db;
use mydia_rs_downloads::ClientRegistry as DownloadClientRegistry;
use mydia_rs_indexers::IndexerRegistry;
use mydia_rs_metadata::ProviderRegistry;
use mydia_rs_pubsub::Pubsub;

/// Shared, clone-cheap handles every apalis worker may need at
/// execution time.
///
/// Workers re-resolve settings from the DB through this context instead
/// of trusting their args payload (matches the Phoenix pattern: args
/// carry IDs, the worker reads `LibraryPath`, `QualityProfile`, etc.
/// fresh from the DB).
#[derive(Clone)]
pub struct AppContext {
    /// Runtime-dispatched sqlx pool (`SQLite` or Postgres).
    pub db: Db,

    /// In-process pubsub bus for progress / status broadcasts. The
    /// graphql subscription resolvers subscribe to the same bus, so
    /// worker-emitted progress fans out to Web UI subscribers without
    /// an extra hop.
    pub pubsub: Pubsub,

    /// Provider registry for metadata fetches (`Relay`, `MusicRelay`, OL).
    /// Workers that touch metadata (e.g. `MetadataRefresh`) pull the
    /// configured provider through this registry rather than knowing
    /// the concrete type.
    pub metadata: Arc<ProviderRegistry>,

    /// Cardigann / Torznab indexer registry. `MovieSearch`,
    /// `TVShowSearch`, and `CardigannHealthCheck` reach for adapters
    /// through this.
    pub indexers: Arc<IndexerRegistry>,

    /// Download-client registry (qBittorrent, Transmission, ...). The
    /// `DownloadMonitor` worker iterates this list every 2 minutes.
    pub downloads: Arc<DownloadClientRegistry>,
}

impl std::fmt::Debug for AppContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Most fields don't impl Debug usefully — print the shape.
        f.debug_struct("AppContext")
            .field("db", &self.db)
            .field("pubsub_attached", &true)
            .field("metadata_provider_count", &self.metadata.len())
            .field("indexers_attached", &true)
            .field("download_client_count", &self.downloads.len())
            .finish_non_exhaustive()
    }
}

impl AppContext {
    /// Build a fully-wired context. The supervision tree calls this
    /// once at boot and clones the result into every worker.
    #[must_use]
    pub fn new(
        db: Db,
        pubsub: Pubsub,
        metadata: Arc<ProviderRegistry>,
        indexers: Arc<IndexerRegistry>,
        downloads: Arc<DownloadClientRegistry>,
    ) -> Self {
        Self {
            db,
            pubsub,
            metadata,
            indexers,
            downloads,
        }
    }
}
