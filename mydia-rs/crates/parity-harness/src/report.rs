//! Structured replay report.
//!
//! Aggregates a `Vec<ReplayResult>` into per-operation buckets and
//! pretty-prints a human-readable summary. The binary in
//! [`crate::bin::replay`] consumes this; integration tests assert
//! against the aggregated counts so passing thresholds drift slowly
//! rather than abruptly.

use std::collections::BTreeMap;
use std::fmt::{self, Write};

use crate::replay::{ReplayOutcome, ReplayResult};

#[derive(Debug, Clone, Default)]
pub struct OperationStats {
    pub matches: usize,
    pub mismatches: usize,
    pub not_implemented: usize,
    pub unexpected_errors: usize,
    pub both_errored: usize,
}

impl OperationStats {
    pub fn total(&self) -> usize {
        self.matches
            + self.mismatches
            + self.not_implemented
            + self.unexpected_errors
            + self.both_errored
    }

    pub fn match_rate(&self) -> f64 {
        let total = self.total();
        if total == 0 {
            return 0.0;
        }
        ((self.matches + self.both_errored) as f64) / (total as f64)
    }
}

#[derive(Debug, Clone, Default)]
pub struct Report {
    pub per_operation: BTreeMap<String, OperationStats>,
}

impl Report {
    pub fn from_results(results: &[ReplayResult]) -> Self {
        let mut per_operation: BTreeMap<String, OperationStats> = BTreeMap::new();
        for result in results {
            let entry = per_operation.entry(result.operation.clone()).or_default();
            match &result.outcome {
                ReplayOutcome::Match => entry.matches += 1,
                ReplayOutcome::Mismatch { .. } => entry.mismatches += 1,
                ReplayOutcome::NotImplemented { .. } => entry.not_implemented += 1,
                ReplayOutcome::UnexpectedError { .. } => entry.unexpected_errors += 1,
                ReplayOutcome::BothErrored => entry.both_errored += 1,
            }
        }
        Self { per_operation }
    }

    pub fn totals(&self) -> OperationStats {
        let mut sum = OperationStats::default();
        for stats in self.per_operation.values() {
            sum.matches += stats.matches;
            sum.mismatches += stats.mismatches;
            sum.not_implemented += stats.not_implemented;
            sum.unexpected_errors += stats.unexpected_errors;
            sum.both_errored += stats.both_errored;
        }
        sum
    }

    /// Coverage gap: operations seen in the corpus that produced zero
    /// matches and zero both-errored outcomes — these are the
    /// resolvers the harness should focus on next.
    pub fn coverage_gaps(&self) -> Vec<&str> {
        self.per_operation
            .iter()
            .filter(|(_, stats)| stats.matches == 0 && stats.both_errored == 0)
            .map(|(name, _)| name.as_str())
            .collect()
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let totals = self.totals();
        writeln!(f, "Parity replay summary")?;
        writeln!(f, "─────────────────────")?;
        writeln!(
            f,
            "Operations:       {} ({:.1}% match)",
            totals.total(),
            totals.match_rate() * 100.0
        )?;
        writeln!(f, "  ✓ Match:        {}", totals.matches)?;
        writeln!(f, "  ⚠ Mismatch:     {}", totals.mismatches)?;
        writeln!(f, "  ⊝ Not impl:     {}", totals.not_implemented)?;
        writeln!(f, "  ✗ Unexpected:   {}", totals.unexpected_errors)?;
        writeln!(f, "  ≈ Both errored: {}", totals.both_errored)?;

        writeln!(f, "\nPer-operation breakdown")?;
        writeln!(f, "───────────────────────")?;
        for (operation, stats) in &self.per_operation {
            writeln!(
                f,
                "{operation}: total={}, match={}, mismatch={}, not_impl={}, unexpected={} ({:.0}%)",
                stats.total(),
                stats.matches,
                stats.mismatches,
                stats.not_implemented,
                stats.unexpected_errors,
                stats.match_rate() * 100.0
            )?;
        }
        Ok(())
    }
}

/// Pretty-print the first few drifts from a result list so callers
/// can spot regressions at a glance. Skipped for non-drift outcomes.
pub fn drift_excerpt(results: &[ReplayResult], limit: usize) -> String {
    let mut out = String::new();
    let mut shown = 0;
    for result in results {
        if shown >= limit {
            break;
        }
        match &result.outcome {
            ReplayOutcome::Mismatch { diffs } => {
                let _ = writeln!(
                    out,
                    "[{}] mismatch ({} diff(s))",
                    result.operation,
                    diffs.len()
                );
                for entry in diffs.iter().take(3) {
                    let _ = writeln!(
                        out,
                        "    {} : {} vs {}",
                        entry.path, entry.left, entry.right
                    );
                }
                shown += 1;
            }
            ReplayOutcome::UnexpectedError { message } => {
                let _ = writeln!(out, "[{}] unexpected error: {message}", result.operation);
                shown += 1;
            }
            _ => {}
        }
    }
    out
}
