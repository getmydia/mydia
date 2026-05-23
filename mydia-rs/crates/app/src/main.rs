//! mydia-rs app entrypoint — driven by `dx serve` / `dioxus::serve`.
//!
//! Server build (`--features server`, the cargo default):
//!   1. Parse CLI / config (figment loads `mydia.toml` + `MYDIA_*` env).
//!   2. Install the tracing subscriber per the logging config.
//!   3. Propagate `config.server.{host,port}` into `IP` / `PORT` env so
//!      `dioxus_cli_config::fullstack_address_or_localhost()` picks
//!      them up. dx sets these itself when running as our parent; we
//!      only set them for standalone invocations.
//!   4. Call `dioxus::serve(closure)`, which:
//!        - Owns the tokio runtime, the listener, and the dev-mode
//!          devtools websocket (hot-reload + hot-patch).
//!        - Calls our closure once at boot, then again on every
//!          hot-patch. We memoize the expensive boot state (DB pool,
//!          runtime lock, OIDC discovery, session migration, apalis
//!          storage) in a `tokio::sync::OnceCell` so only the first
//!          call pays for it; subsequent calls just rebuild the
//!          Router from cached handles.
//!
//! Web build (`--features web --no-default-features`, used by `dx serve`
//! when targeting wasm32-unknown-unknown):
//!   Just `dioxus::launch(mydia_rs_web::app)`. All hydration plumbing
//!   is handled by Dioxus internals; this file does nothing else on
//!   that target.
//!
//! `--keep-alive` is a no-op kept for compose compatibility.

// ============================================================
// Web (wasm) target — hydration client.
// ============================================================
#[cfg(all(feature = "web", not(feature = "server")))]
fn main() {
    dioxus::launch(mydia_rs_web::app);
}

// ============================================================
// Server target — axum + Dioxus SSR via dioxus::serve.
// ============================================================
#[cfg(feature = "server")]
use std::path::PathBuf;
#[cfg(feature = "server")]
use std::sync::Arc;

#[cfg(feature = "server")]
use anyhow::{anyhow, Context};
#[cfg(feature = "server")]
use clap::Parser;
#[cfg(feature = "server")]
use mydia_rs_app::runtime_lock::{self, RuntimeLockError, RuntimeLockHandle};
#[cfg(feature = "server")]
use mydia_rs_app::server;
#[cfg(feature = "server")]
use mydia_rs_config::{tracing_setup, Config};
#[cfg(feature = "server")]
use mydia_rs_db::{connect_from_config, schema_check, Db, SchemaCheckOutcome};
#[cfg(feature = "server")]
use mydia_rs_jobs::storage::{self as jobs_storage, JobStorage};
#[cfg(feature = "server")]
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
#[cfg(feature = "server")]
use mydia_rs_pubsub::Pubsub;
#[cfg(feature = "server")]
use mydia_rs_web::oidc::{OidcContext, OidcSettings};
#[cfg(feature = "server")]
use mydia_rs_web::session as web_session;
#[cfg(feature = "server")]
use mydia_rs_web::WebState;
#[cfg(feature = "server")]
use tokio::sync::OnceCell;

/// CLI surface for the mydia-rs binary.
#[cfg(feature = "server")]
#[derive(Debug, Parser)]
#[command(
    name = "mydia-rs",
    version,
    about = "mydia Rust backend (parallel reimplementation of the Phoenix stack)"
)]
struct Cli {
    /// Path to the mydia.toml configuration file. When absent, defaults
    /// and environment variables alone are used.
    #[arg(long, env = "MYDIA_CONFIG", value_name = "PATH")]
    config: Option<PathBuf>,

    /// Retained for compose compatibility; the HTTP server holds the
    /// runtime open by itself, so this is now a no-op.
    #[arg(long, env = "MYDIA_KEEP_ALIVE", default_value_t = false)]
    keep_alive: bool,
}

/// Long-lived handles, built once at boot and reused across hot-patches.
/// Held inside [`BOOT`]; the lock survives until the process is killed.
#[cfg(feature = "server")]
struct BootState {
    web_state: WebState,
    db: Db,
    /// Held for the lifetime of the process so the lock row stays
    /// claimed. `RuntimeLockHandle` releases on `Drop`, which only
    /// fires on clean shutdown — dx's full-rebuild SIGTERM gives us
    /// that, and the `SQLite` row's `STALE_AFTER` covers the SIGKILL
    /// case. `None` when `MYDIA_RS_DEV_SKIP_LOCK=true`.
    _lock: Option<RuntimeLockHandle>,
}

#[cfg(feature = "server")]
fn main() {
    let cli = Cli::parse();

    let config = match Config::load(cli.config.as_deref()) {
        Ok(cfg) => cfg,
        Err(err) => {
            // Tracing is not installed yet; surface the failure on stderr
            // so a misconfigured boot is immediately visible.
            eprintln!("mydia-rs: configuration error: {err}");
            std::process::exit(1);
        }
    };

    if let Err(err) = tracing_setup::install(&config.logging) {
        eprintln!("mydia-rs: failed to install tracing subscriber: {err}");
        std::process::exit(1);
    }

    // dx sets PORT / IP env vars when it spawns us as a subprocess
    // (the dx proxy expects us on that port). When running standalone
    // (`./dev rs run`, `cargo run`, production), dx isn't there — we
    // propagate config.server into the same env vars so
    // `dioxus_cli_config::fullstack_address_or_localhost()` lands on
    // the operator-configured address. set_var only when unset so
    // dx's value always wins under hot-reload.
    //
    // SAFETY: set_var is not thread-safe in general, but we're in
    // main() before any threads exist.
    unsafe {
        if std::env::var_os("PORT").is_none() {
            std::env::set_var("PORT", config.server.port.to_string());
        }
        if std::env::var_os("IP").is_none() {
            std::env::set_var("IP", &config.server.host);
        }
    }

    // The boot state is materialized once on the first closure call and
    // reused on every subsequent hot-patch. Static so it lives as long
    // as the process.
    static BOOT: OnceCell<Arc<BootState>> = OnceCell::const_new();

    let config = Arc::new(config);
    let keep_alive = cli.keep_alive;

    dioxus::serve(move || {
        let config = config.clone();
        async move {
            let boot = BOOT
                .get_or_try_init(|| async {
                    tracing::info!(
                        version = env!("CARGO_PKG_VERSION"),
                        db_type = ?config.database.db_type,
                        host = %config.server.host,
                        port = config.server.port,
                        keep_alive,
                        "mydia-rs boot starting"
                    );
                    bootstrap(&config).await.map(Arc::new)
                })
                .await?;

            let session_layer = web_session::layer(&boot.db, !cfg!(debug_assertions));
            Ok(server::build_router(boot.web_state.clone(), session_layer))
        }
    });
}

/// Run the expensive one-time boot sequence and assemble [`BootState`].
///
/// Invariants assumed by callers (the closure passed to `dioxus::serve`):
///   - tracing is already installed; logs from here on use the
///     configured subscriber.
///   - It is safe to fail; the error propagates out of the closure to
///     `dioxus::serve`, which logs and re-tries on the next hot-patch.
#[cfg(feature = "server")]
async fn bootstrap(config: &Config) -> anyhow::Result<BootState> {
    let db = connect_from_config(config)
        .await
        .context("failed to open database")?;

    match schema_check(&db).await.context("schema check failed")? {
        SchemaCheckOutcome::Match { version } => {
            tracing::info!(version, "schema check passed");
        }
        SchemaCheckOutcome::SchemaAhead { version } => {
            tracing::warn!(version, "schema ahead of binary; continuing");
        }
        SchemaCheckOutcome::SchemaTooOld { version } => {
            return Err(anyhow!(
                "schema older than binary expects (version {version}); refusing to start"
            ));
        }
        SchemaCheckOutcome::SchemaMissing => {
            // Bare smoke against an un-migrated file is acceptable for
            // the current bring-up phase. Tighten this to a hard
            // failure once a real supervision tree exists.
            tracing::warn!("schema_migrations missing; this may not be a mydia database");
        }
    }

    // MYDIA_RS_DEV_SKIP_LOCK=true bypasses the U34 mutual-exclusion
    // check. Load-bearing for full-rebuild restart cycles where dx
    // SIGKILLs the old binary before its lock-release path runs,
    // leaving a 30-second-fresh lock row that blocks the new boot.
    // Production must never set this.
    //
    // Note: this env var deliberately doesn't start with `MYDIA_`
    // because figment consumes that prefix as Config schema overrides
    // and `deny_unknown_fields` would reject an unrecognized name.
    let lock_enabled = !matches!(
        std::env::var("MYDIA_RS_DEV_SKIP_LOCK")
            .unwrap_or_default()
            .to_lowercase()
            .as_str(),
        "true" | "1" | "yes" | "on"
    );

    let lock = if lock_enabled {
        match runtime_lock::acquire(&db).await {
            Ok(handle) => Some(handle),
            Err(RuntimeLockError::Held) => {
                return Err(anyhow!(
                    "another mydia instance is running against this database; refusing to start"
                ));
            }
            Err(err) => {
                return Err(anyhow::Error::new(err).context("failed to acquire runtime lock"));
            }
        }
    } else {
        tracing::warn!(
            "MYDIA_RS_DEV_SKIP_LOCK=true — boot-time mutual-exclusion lock skipped. \
             DEV ONLY; production must not set this."
        );
        None
    };

    // Wire the in-process pubsub bus + the apalis storage for the
    // LibraryScanner worker. U23 only needs the one worker's storage;
    // U24-U28 admin pages that trigger jobs will pull their storages
    // into WebState the same way.
    jobs_storage::setup(&db)
        .await
        .context("apalis storage setup failed")?;

    // U24.a — create the `tower_sessions` table if absent. One of the
    // two mydia-rs-owned tables (the other is U34's runtime-lock).
    // Phoenix's Ecto schemas don't model it, so the "no migrations
    // from mydia-rs" rule's explicit exceptions cover it.
    web_session::migrate(&db)
        .await
        .context("tower-sessions table migration failed")?;

    let pubsub = Pubsub::new();
    let library_scanner_storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);

    // OIDC discovery happens once at boot. Failure is logged but not
    // fatal — the rest of the app boots with password auth only, and
    // the login page hides the OIDC button via `WebState::oidc_available`.
    let oidc = build_oidc_context(config).await.map(Arc::new);

    let web_state = WebState::new(db.clone(), pubsub, library_scanner_storage, oidc);

    tracing::info!("mydia-rs boot ok");

    Ok(BootState {
        web_state,
        db,
        _lock: lock,
    })
}

/// Translate the `AuthConfig` OIDC fields into the web crate's
/// [`OidcSettings`] shape and run discovery. Returns `None` when OIDC
/// is disabled in config (the common case for self-hosters who only
/// run password auth) or when discovery fails (logged).
#[cfg(feature = "server")]
async fn build_oidc_context(config: &Config) -> Option<OidcContext> {
    let auth = &config.auth;
    if !auth.oidc_enabled {
        tracing::debug!("OIDC disabled in config; skipping discovery");
        return None;
    }

    let (Some(client_id), Some(client_secret), Some(redirect_uri)) = (
        auth.oidc_client_id.clone(),
        auth.oidc_client_secret.clone(),
        auth.oidc_redirect_uri.clone(),
    ) else {
        tracing::error!(
            "OIDC enabled but client_id / client_secret / redirect_uri missing — skipping"
        );
        return None;
    };

    let settings = OidcSettings {
        issuer: auth.oidc_issuer.clone(),
        discovery_document_uri: auth.oidc_discovery_document_uri.clone(),
        client_id,
        client_secret,
        redirect_uri,
        scopes: auth.oidc_scopes.clone(),
        disable_par: auth.oidc_disable_par,
    };

    match OidcContext::try_build(&settings).await {
        Some(ctx) => {
            tracing::info!(
                issuer = ?settings.issuer,
                "OIDC provider discovered; PKCE flow available at /auth/oidc/login"
            );
            Some(ctx)
        }
        None => {
            // try_build already logged the underlying cause.
            None
        }
    }
}
