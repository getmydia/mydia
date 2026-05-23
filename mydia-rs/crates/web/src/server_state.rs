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

use std::sync::Arc;

use mydia_rs_auth::{MediaTokenCache, MediaTokenSigner};
use mydia_rs_db::Db;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_pubsub::Pubsub;

use crate::oidc::OidcContext;

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

    /// OIDC client and discovered provider metadata, built once at
    /// boot. `None` when OIDC is disabled in config or discovery
    /// failed at startup (logged with the underlying cause). Pages
    /// query [`Self::oidc_available`] to decide whether to render
    /// the "Sign in with OIDC" button.
    pub oidc: Option<Arc<OidcContext>>,

    /// Media-token signer used by the REST `media_api_auth` pipeline
    /// (`/api/v1/stream/*`, `/api/v1/hls/*`). `None` when the
    /// `guardian_secret_key` is absent from config; in that case the
    /// media-token-authenticated routes return 401 because no token
    /// can be verified. Built once at boot so verifications are
    /// allocation-free on the hot path.
    pub media_signer: Option<MediaTokenSigner>,

    /// In-process verified-claims cache for the media-token pipeline.
    /// Shared with the p2p subsystem so admin device-revoke evicts here
    /// too. `None` when the signer is unset (no point caching what we
    /// can't verify).
    pub media_token_cache: Option<MediaTokenCache>,

    /// Generated-media base directory (`thumbnails`, sprites, VTT) as
    /// resolved at boot. Mirrors Phoenix's
    /// `Application.get_env(:mydia, :generated_media_path)`. Defaults
    /// to `priv/generated` when nothing is configured. Stored as
    /// `Arc<PathBuf>` so clones stay cheap.
    pub generated_media_path: Arc<std::path::PathBuf>,
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
        oidc: Option<Arc<OidcContext>>,
    ) -> Self {
        Self {
            db,
            pubsub,
            library_scanner_storage,
            oidc,
            media_signer: None,
            media_token_cache: None,
            generated_media_path: Arc::new(default_generated_media_path()),
        }
    }

    /// Attach a media-token signer + cache. Called by the boot path
    /// after `WebState::new` once the `guardian_secret_key` is known.
    /// Without this, the `/api/v1/stream` and `/api/v1/hls` routes
    /// always 401 because their middleware has no verifier to call.
    #[must_use]
    pub fn with_media_signer(mut self, signer: MediaTokenSigner, cache: MediaTokenCache) -> Self {
        self.media_signer = Some(signer);
        self.media_token_cache = Some(cache);
        self
    }

    /// Override the generated-media base path. Defaults to
    /// `priv/generated` when the env var is unset. Callers (boot path,
    /// tests) pass the resolved config path here.
    #[must_use]
    pub fn with_generated_media_path(mut self, path: std::path::PathBuf) -> Self {
        self.generated_media_path = Arc::new(path);
        self
    }

    /// Server-side check used by the login page to decide whether to
    /// render the OIDC button. Reads through a fresh clone so the
    /// page can ask this without holding any internal handles.
    #[must_use]
    pub fn oidc_available(&self) -> bool {
        self.oidc.is_some()
    }
}

/// Resolve the generated-media base path the same way the Phoenix
/// `Mydia.Library.GeneratedMedia.base_path/0` does: env var override
/// first (`MYDIA_GENERATED_MEDIA_PATH`), fall back to `priv/generated`
/// to match dev-mode Phoenix output. Boot callers replace this with
/// the config-resolved value via [`WebState::with_generated_media_path`].
fn default_generated_media_path() -> std::path::PathBuf {
    std::env::var("MYDIA_GENERATED_MEDIA_PATH")
        .ok()
        .map_or_else(|| std::path::PathBuf::from("priv/generated"), Into::into)
}
