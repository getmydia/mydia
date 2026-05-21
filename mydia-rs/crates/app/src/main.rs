//! mydia-rs app entrypoint.
//!
//! Today's binary loads config, installs the tracing subscriber, logs a
//! "boot ok" line, and exits. The supervision tree (DB pool, HTTP server,
//! P2P host, background workers) lands in subsequent units.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use mydia_rs_config::{tracing_setup, Config};

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
            "mydia-rs boot ok (U3: config + tracing); exiting"
        );
    });

    ExitCode::SUCCESS
}
