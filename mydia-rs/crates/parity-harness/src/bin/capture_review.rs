//! `parity-review` — inspect a captured GraphQL parity corpus.
//!
//! Invocation:
//!
//!     cargo run -p mydia-rs-parity-harness --bin parity-review -- \
//!       --corpus /path/to/capture.jsonl
//!
//! Reports:
//!
//! - Total record count, skipped-line count
//! - Per-operation count and success rate
//! - Average elapsed time per operation
//! - First N anonymous-operation queries (helps spot un-named queries
//!   the Flutter player issues that the parity replay can't easily
//!   bucket)
//!
//! The replay binary that compares mydia-rs output to Phoenix's
//! captured responses lands in U13.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use mydia_rs_parity_harness::{load_corpus, CaptureRecord};

#[derive(Debug, Parser)]
#[command(
    name = "parity-review",
    version,
    about = "Inspect a captured mydia GraphQL parity corpus"
)]
struct Cli {
    /// Path to a JSONL corpus produced by MydiaWeb.Plugs.ParityCapture.
    #[arg(long, value_name = "PATH")]
    corpus: PathBuf,

    /// Maximum number of anonymous-query samples to print.
    #[arg(long, default_value_t = 5)]
    anonymous_samples: usize,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let load = match load_corpus(&cli.corpus) {
        Ok(load) => load,
        Err(err) => {
            eprintln!(
                "parity-review: failed to load {}: {err}",
                cli.corpus.display()
            );
            return ExitCode::FAILURE;
        }
    };

    println!("corpus: {}", cli.corpus.display());
    println!("records: {}", load.records.len());
    println!("skipped lines: {}", load.skipped.len());

    if !load.skipped.is_empty() {
        println!();
        println!("== Skipped lines ==");
        for skipped in load.skipped.iter().take(10) {
            println!("  line {}: {}", skipped.line, skipped.reason);
        }
        if load.skipped.len() > 10 {
            println!("  ... and {} more", load.skipped.len() - 10);
        }
    }

    let mut groups: BTreeMap<String, OperationStats> = BTreeMap::new();
    for record in &load.records {
        let label = record.operation_label().to_owned();
        groups.entry(label).or_default().add(record);
    }

    println!();
    println!("== Per-operation summary ==");
    println!(
        "{:<32} {:>8} {:>8} {:>12} {:>14}",
        "operation", "count", "success", "errors", "avg elapsed"
    );
    for (op, stats) in &groups {
        println!(
            "{:<32} {:>8} {:>8} {:>12} {:>12} ms",
            truncate(op, 32),
            stats.count,
            stats.success,
            stats.count - stats.success,
            stats.average_elapsed_ms()
        );
    }

    if cli.anonymous_samples > 0 {
        let samples: Vec<&CaptureRecord> = load
            .records
            .iter()
            .filter(|r| r.operation.is_none())
            .take(cli.anonymous_samples)
            .collect();
        if !samples.is_empty() {
            println!();
            println!("== Anonymous query samples ==");
            for (idx, record) in samples.iter().enumerate() {
                println!(
                    "{}. status={} elapsed_ms={}",
                    idx + 1,
                    record.status,
                    record.elapsed_ms
                );
                if let Some(q) = &record.query {
                    println!("   query: {}", truncate(q, 120));
                }
            }
        }
    }

    ExitCode::SUCCESS
}

#[derive(Default)]
struct OperationStats {
    count: usize,
    success: usize,
    elapsed_ms_total: i64,
}

impl OperationStats {
    fn add(&mut self, record: &CaptureRecord) {
        self.count += 1;
        if record.is_successful() {
            self.success += 1;
        }
        self.elapsed_ms_total += record.elapsed_ms;
    }

    fn average_elapsed_ms(&self) -> i64 {
        if self.count == 0 {
            0
        } else {
            self.elapsed_ms_total / self.count as i64
        }
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_owned()
    } else {
        format!("{}…", &s[..max.saturating_sub(1)])
    }
}
