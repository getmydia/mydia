//! `parity-replay` — run a captured GraphQL parity corpus against
//! the mydia-rs schema.
//!
//! Invocation:
//!
//!     cargo run -p mydia-rs-parity-harness --bin parity-replay -- \
//!       --corpus path/to/capture.jsonl --database path/to/mydia.db
//!
//! The schema is built with the same builder mydia-rs uses at boot
//! (`mydia_rs_graphql::build_schema`), so the comparison surface is
//! identical to what a live Flutter player would talk to. The
//! database connection points at a copy of the operator's DB — the
//! replay never writes (read-only resolvers); the mutations that DO
//! write are surfaced as `mismatch` if their side effects matter for
//! parity.
//!
//! Exit code:
//!
//! - 0 — every record matched or both-errored.
//! - 1 — at least one record drifted (mismatch or unexpected error).
//! - 2 — fatal setup error (corpus unreadable, schema build failure,
//!   database unreachable).

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::connect_from_config;
use mydia_rs_graphql::{build_schema, GraphqlAppState};
use mydia_rs_parity_harness::{drift_excerpt, load_corpus, replay_corpus, RedactionSet, Report};

#[derive(Debug, Parser)]
#[command(
    name = "parity-replay",
    version,
    about = "Replay a captured GraphQL parity corpus against mydia-rs"
)]
struct Cli {
    /// Path to the JSONL corpus produced by Phoenix's
    /// `MydiaWeb.Plugs.ParityCapture`.
    #[arg(long)]
    corpus: PathBuf,

    /// Path to a SQLite database, OR a Postgres URL. When set to a
    /// path, defaults to SQLite. When prefixed with `postgres://`, the
    /// Postgres driver is used.
    #[arg(long, default_value = ":memory:")]
    database: String,

    /// Path-prefixed redaction patterns to apply on top of the
    /// defaults. Use dotted notation with `*` wildcards.
    #[arg(long = "redact")]
    extra_redactions: Vec<String>,

    /// Print full mismatch diffs (limited to `--max-drift-excerpts`).
    #[arg(long, default_value_t = false)]
    verbose: bool,

    /// Maximum number of mismatch/unexpected-error excerpts to print.
    #[arg(long, default_value_t = 5)]
    max_drift_excerpts: usize,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();

    let load = match load_corpus(&cli.corpus) {
        Ok(load) => load,
        Err(err) => {
            eprintln!("Failed to load corpus: {err}");
            return ExitCode::from(2);
        }
    };
    if !load.skipped.is_empty() {
        eprintln!(
            "Skipped {} malformed line(s) in {}",
            load.skipped.len(),
            cli.corpus.display()
        );
    }
    eprintln!(
        "Loaded {} record(s) from {}",
        load.records.len(),
        cli.corpus.display()
    );

    let config = build_config(&cli.database);
    let db = match connect_from_config(&config).await {
        Ok(db) => db,
        Err(err) => {
            eprintln!("Failed to connect to database `{}`: {err}", cli.database);
            return ExitCode::from(2);
        }
    };
    let schema = build_schema(GraphqlAppState::new(db));

    let mut extra = RedactionSet::new();
    for path in cli.extra_redactions {
        extra = extra.redact(&path);
    }

    let results = replay_corpus(&schema, &load.records, extra).await;
    let report = Report::from_results(&results);
    println!("{report}");
    if cli.verbose {
        let excerpt = drift_excerpt(&results, cli.max_drift_excerpts);
        if !excerpt.is_empty() {
            println!("\nDrift excerpts");
            println!("──────────────");
            print!("{excerpt}");
        }
    }

    let gaps = report.coverage_gaps();
    if !gaps.is_empty() {
        println!(
            "\nCoverage gaps ({} operations with zero matches):",
            gaps.len()
        );
        for op in gaps.iter().take(20) {
            println!("  - {op}");
        }
        if gaps.len() > 20 {
            println!("  ... and {} more", gaps.len() - 20);
        }
    }

    let totals = report.totals();
    if totals.mismatches == 0 && totals.unexpected_errors == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn build_config(database: &str) -> Config {
    if database.starts_with("postgres://") || database.starts_with("postgresql://") {
        Config {
            database: DatabaseConfig {
                db_type: DatabaseType::Postgres,
                url: Some(database.to_owned()),
                path: None,
                pool_size: 2,
                ..DatabaseConfig::default()
            },
            ..Config::default()
        }
    } else {
        Config {
            database: DatabaseConfig {
                db_type: DatabaseType::Sqlite,
                url: None,
                path: Some(database.to_owned()),
                pool_size: 2,
                ..DatabaseConfig::default()
            },
            ..Config::default()
        }
    }
}
