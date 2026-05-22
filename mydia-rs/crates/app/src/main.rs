//! mydia-rs app entrypoint — dual-target per Dioxus 0.7's `dx serve` model.
//!
//! Server build (`--features server`, the cargo default):
//!   1. Parse CLI / config (figment loads `mydia.toml` + `MYDIA_*` env).
//!   2. Install the tracing subscriber per the logging config.
//!   3. Build the multi-thread tokio runtime.
//!   4. Open the DB pool (sqlx, `SQLite` or Postgres per `database.type`).
//!   5. Schema-drift probe (warns on DB ahead, refuses on DB behind).
//!   6. Acquire the boot-time mutual-exclusion lock (U34).
//!   7. Mount the axum + Dioxus router (U22) and serve until shutdown.
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
// Server target — axum + Dioxus SSR.
// ============================================================
#[cfg(feature = "server")]
use std::path::PathBuf;
#[cfg(feature = "server")]
use std::process::ExitCode;

#[cfg(feature = "server")]
use clap::Parser;
#[cfg(feature = "server")]
use mydia_rs_app::runtime_lock::{self, RuntimeLockError};
#[cfg(feature = "server")]
use mydia_rs_app::server;
#[cfg(feature = "server")]
use mydia_rs_config::{tracing_setup, Config};
#[cfg(feature = "server")]
use mydia_rs_db::{connect_from_config, schema_check, SchemaCheckOutcome};

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

#[cfg(feature = "server")]
fn main() -> ExitCode {
    let cli = Cli::parse();

    let mut config = match Config::load(cli.config.as_deref()) {
        Ok(cfg) => cfg,
        Err(err) => {
            // Tracing is not installed yet; surface the failure on stderr
            // so a misconfigured boot is immediately visible.
            eprintln!("mydia-rs: configuration error: {err}");
            return ExitCode::FAILURE;
        }
    };

    // dx serve owns the user-facing port (--port flag) and spawns
    // our binary as a subprocess, expecting it to bind a different
    // port that dx then proxies to. dx passes that port via the
    // standard PORT / IP env vars. Honor them on top of config so
    // the dev-container hot-reload path works without operator
    // config changes; native `cargo run` doesn't set these, so the
    // config values still apply there.
    if let Ok(port_str) = std::env::var("PORT") {
        if let Ok(port) = port_str.parse::<u16>() {
            config.server.port = port;
        }
    }
    if let Ok(host) = std::env::var("IP") {
        config.server.host = host;
    }

    if let Err(err) = tracing_setup::install(&config.logging) {
        eprintln!("mydia-rs: failed to install tracing subscriber: {err}");
        return ExitCode::FAILURE;
    }

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            tracing::error!(%err, "failed to build tokio runtime");
            return ExitCode::FAILURE;
        }
    };

    runtime.block_on(async move {
        tracing::info!(
            version = env!("CARGO_PKG_VERSION"),
            db_type = ?config.database.db_type,
            host = %config.server.host,
            port = config.server.port,
            keep_alive = cli.keep_alive,
            "mydia-rs boot starting"
        );

        let db = match connect_from_config(&config).await {
            Ok(db) => db,
            Err(err) => {
                tracing::error!(%err, "failed to open database");
                return ExitCode::FAILURE;
            }
        };

        match schema_check(&db).await {
            Ok(SchemaCheckOutcome::Match { version }) => {
                tracing::info!(version, "schema check passed");
            }
            Ok(SchemaCheckOutcome::SchemaAhead { version }) => {
                tracing::warn!(version, "schema ahead of binary; continuing");
            }
            Ok(SchemaCheckOutcome::SchemaTooOld { version }) => {
                tracing::error!(
                    version,
                    "schema older than binary expects; refusing to start"
                );
                return ExitCode::FAILURE;
            }
            Ok(SchemaCheckOutcome::SchemaMissing) => {
                // Bare smoke against an un-migrated file is acceptable
                // for the current bring-up phase. Tighten this to a
                // hard failure once a real supervision tree exists.
                tracing::warn!("schema_migrations missing; this may not be a mydia database");
            }
            Err(err) => {
                tracing::error!(%err, "schema check failed");
                return ExitCode::FAILURE;
            }
        }

        // MYDIA_RS_DEV_SKIP_LOCK=true skips the U34 mutual-
        // exclusion check. ONLY for dev hot-reload loops where
        // cargo-watch SIGKILLs the old binary before its lock-
        // release path runs, leaving a 30-second-fresh lock row
        // that blocks the new binary from starting. Production
        // must not set this — the lock is the only thing keeping
        // two backends off the same DB.
        //
        // Note: this env var deliberately doesn't start with
        // `MYDIA_` because figment consumes that prefix as Config
        // schema overrides and `deny_unknown_fields` would reject
        // an unrecognized name.
        let lock_enabled = !matches!(
            std::env::var("MYDIA_RS_DEV_SKIP_LOCK")
                .unwrap_or_default()
                .to_lowercase()
                .as_str(),
            "true" | "1" | "yes" | "on"
        );

        let lock = if lock_enabled {
            match runtime_lock::acquire(&db).await {
                Ok(lock) => Some(lock),
                Err(RuntimeLockError::Held) => {
                    tracing::error!(
                        "another mydia instance is running against this database; refusing to start"
                    );
                    return ExitCode::FAILURE;
                }
                Err(err) => {
                    tracing::error!(%err, "failed to acquire runtime lock");
                    return ExitCode::FAILURE;
                }
            }
        } else {
            tracing::warn!(
                "MYDIA_RS_DEV_SKIP_LOCK=true — boot-time mutual-exclusion lock skipped. \
                 DEV ONLY; production must not set this."
            );
            None
        };

        tracing::info!("mydia-rs boot ok (U22 SSR mount next)");

        let router = server::build_router();
        let serve_result = server::serve(&config, router, wait_for_shutdown_signal()).await;

        if let Some(lock) = lock {
            if let Err(err) = lock.release().await {
                tracing::warn!(%err, "runtime lock release failed; row will time out");
            }
        }

        match serve_result {
            Ok(()) => {
                tracing::info!("shutdown complete");
                ExitCode::SUCCESS
            }
            Err(err) => {
                tracing::error!(%err, "axum server exited with error");
                ExitCode::FAILURE
            }
        }
    })
}

/// Block until SIGTERM (docker stop) or SIGINT (Ctrl-C) arrives.
/// On non-unix targets falls back to `ctrl_c` only.
#[cfg(all(feature = "server", unix))]
async fn wait_for_shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = match signal(SignalKind::terminate()) {
        Ok(s) => s,
        Err(err) => {
            tracing::warn!(%err, "could not install SIGTERM handler; falling back to ctrl_c only");
            let _ = tokio::signal::ctrl_c().await;
            return;
        }
    };
    tokio::select! {
        _ = sigterm.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}

#[cfg(all(feature = "server", not(unix)))]
async fn wait_for_shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
