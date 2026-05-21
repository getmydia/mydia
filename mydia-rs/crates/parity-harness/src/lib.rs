//! GraphQL parity capture and replay tooling.
//!
//! U9 ships the capture side: the JSONL [`corpus`] reader/writer and
//! the [`diff`] module with redaction rules. The Phoenix-side
//! `MydiaWeb.Plugs.ParityCapture` produces the corpus; this crate
//! consumes it.
//!
//! U13 lands the replay surface — [`replay`] runs each corpus record
//! through the mydia-rs async-graphql schema, [`report`] aggregates the
//! outcomes, and the `parity-replay` binary stitches the two
//! together. The `parity-review` binary from U9 stays as the
//! inspection tool — it surveys an existing corpus and reports
//! operation counts, error rates, and basic shape statistics without
//! running the replay.

pub mod corpus;
pub mod diff;
pub mod replay;
pub mod report;

pub use corpus::{
    append_record, load_corpus, load_corpus_from_reader, CaptureRecord, CorpusError, CorpusLoad,
    SkippedLine,
};
pub use diff::{diff, DiffEntry, RedactionSet};
pub use replay::{replay_corpus, replay_one, ReplayOutcome, ReplayResult};
pub use report::{drift_excerpt, OperationStats, Report};
