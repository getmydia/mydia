//! mydia-rs app entrypoint.
//!
//! Today's binary loads config, installs the tracing subscriber, logs a
//! "boot ok" line, and exits. The supervision tree (DB pool, HTTP server,
//! P2P host, background workers) lands in subsequent units.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use mydia_rs_app::runtime_lock::{self, RuntimeLockError};
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

    runtime.block_on(async {
        tracing::info!(
            version = env!("CARGO_PKG_VERSION"),
            db_type = ?config.database.db_type,
            host = %config.server.host,
            port = config.server.port,
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
                tracing::error!(version, "schema older than binary expects; refusing to start");
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

        tracing::info!("mydia-rs boot ok (U34: runtime lock held); exiting");

        if let Err(err) = lock.release().await {
            tracing::warn!(%err, "runtime lock release failed; row will time out");
        }

        ExitCode::SUCCESS
    })
}
