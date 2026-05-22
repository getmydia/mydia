//! mydia-rs app entrypoint.
//!
//! Boot order:
//!   1. Parse CLI / config (figment loads `mydia.toml` + `MYDIA_*` env).
//!   2. Install the tracing subscriber per the logging config.
//!   3. Build the multi-thread tokio runtime.
//!   4. Open the DB pool (sqlx, `SQLite` or Postgres per `database.type`).
//!   5. Schema-drift probe (warns on DB ahead, refuses on DB behind).
//!   6. Acquire the boot-time mutual-exclusion lock (U34).
//!   7. Mount the axum + Dioxus router (U22) and serve until shutdown.
//!
//! `--keep-alive` (used by the docker-compose service so the image
//! doesn't restart-loop during pre-U22 testing) is now a no-op: the
//! HTTP server holds the runtime open until SIGTERM / SIGINT. The
//! flag stays in the CLI for compose compatibility but doesn't change
//! behavior — the loop runs unconditionally because there's a real
//! server to host now.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use mydia_rs_app::runtime_lock::{self, RuntimeLockError};
use mydia_rs_app::server;
use mydia_rs_config::{tracing_setup, Config};
use mydia_rs_db::{connect_from_config, schema_check, SchemaCheckOutcome};

/// CLI surface for the mydia-rs binary.
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

fn main() -> ExitCode {
    let cli = Cli::parse();

    let config = match Config::load(cli.config.as_deref()) {
        Ok(cfg) => cfg,
        Err(err) => {
            // Tracing is not installed yet; surface the failure on stderr
            // so a misconfigured boot is immediately visible.
            eprintln!("mydia-rs: configuration error: {err}");
            return ExitCode::FAILURE;
        }
    };

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

        let lock = match runtime_lock::acquire(&db).await {
            Ok(lock) => lock,
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
        };

        tracing::info!("mydia-rs boot ok (U34 lock held; U22 SSR mount next)");

        let router = server::build_router();
        let serve_result = server::serve(&config, router, wait_for_shutdown_signal()).await;

        if let Err(err) = lock.release().await {
            tracing::warn!(%err, "runtime lock release failed; row will time out");
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
#[cfg(unix)]
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

#[cfg(not(unix))]
async fn wait_for_shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
