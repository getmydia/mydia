//! Server-only handle injected into the axum request extensions for
//! server functions and realtime upgrade handlers.
//!
//! Server functions in Dioxus 0.7 don't take an explicit `State<T>`
//! argument — they reach for request data through [`FullstackContext`].
//! That context's `extension::<T>()` method reads a typed entry out of
//! the request's `Extensions` map, populated by an axum `Extension`
//! layer attached when the router is built.
//!
//! For U23 (the Dioxus pilot) we keep this lean: just the DB pool, the
//! pubsub bus, and the apalis storage for the one worker the pilot
//! needs to enqueue. U24+ pages will need more (auth session, the rest
//! of the registries from `mydia_rs_jobs::AppContext`); fold those in
//! here as they land so callers stay on one consistent extension type
//! rather than learning a new `Extension<X>` per page.

// Module-level cfg gate lives in `lib.rs` (`pub mod server_state` under
// `#[cfg(feature = "server")]`); no need to repeat it here.

use mydia_rs_db::Db;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_pubsub::Pubsub;

/// Cheap-to-clone bundle of shared, server-side handles. Held inside
/// an `axum::Extension<WebState>` so a request can pull it without
/// touching axum state generics.
///
/// **Cloning is `O(1)`** — every field is an `Arc` (or a newtype that
/// wraps `Arc<Inner>`) under the hood, so the per-request copy is
/// effectively a refcount bump.
#[derive(Clone)]
pub struct WebState {
    /// Runtime-dispatched sqlx pool (`SQLite` or Postgres).
    pub db: Db,

    /// In-process pubsub bus. Library-scan, jobs:status, downloads,
    /// transcodes, and (later) GraphQL subscriptions all fan out here.
    pub pubsub: Pubsub,

    /// apalis storage for the `LibraryScanner` worker. The admin
    /// library-paths page enqueues against this when an operator
    /// clicks "Scan now"; cloning is cheap and `push` only needs
    /// `&mut self` on a fresh clone.
    pub library_scanner_storage: JobStorage<LibraryScannerArgs>,
}

impl WebState {
    /// Build a [`WebState`] from already-initialized handles.
    ///
    /// Callers (the `mydia-rs-app` boot path) must:
    ///   1. Run `mydia_rs_jobs::storage::setup(&db).await` before
    ///      constructing the [`JobStorage`] so the queue tables exist.
    ///   2. Share the same [`Pubsub`] instance with the worker monitor
    ///      so scans enqueued here publish on the bus a WS upgrade can
    ///      subscribe to.
    #[must_use]
    pub fn new(
        db: Db,
        pubsub: Pubsub,
        library_scanner_storage: JobStorage<LibraryScannerArgs>,
    ) -> Self {
        Self {
            db,
            pubsub,
            library_scanner_storage,
        }
    }
}
