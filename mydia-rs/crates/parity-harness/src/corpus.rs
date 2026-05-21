//! JSONL corpus reader and writer.
//!
//! One [`CaptureRecord`] per JSONL line, matching the shape Phoenix's
//! `MydiaWeb.Plugs.ParityCapture` emits. The reader is forgiving:
//! malformed lines are skipped with a logged warning (the player's
//! ~30-minute session can produce thousands of records, and dropping
//! the entire corpus because one line had a stray byte is worse than
//! reporting one fewer record).

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One captured GraphQL request/response pair.
///
/// Field ordering matches the Phoenix plug's record emission. The
/// `response` field is the parsed Phoenix response JSON (`{"data":
/// {...}, "errors": [...]}`). On responses that weren't valid JSON,
/// the plug emits `{"_unparseable_body": "<raw string>"}` so the
/// shape stays uniform.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CaptureRecord {
    /// Absinthe operation name, if the client supplied one.
    /// Anonymous queries leave this `null`.
    #[serde(default)]
    pub operation: Option<String>,
    /// Raw GraphQL query string.
    #[serde(default)]
    pub query: Option<String>,
    /// Variables map (any JSON object) or `null` when absent.
    #[serde(default)]
    pub variables: Option<serde_json::Value>,
    /// Parsed response body, as JSON. May be `null` if the resolver
    /// produced no body at all.
    #[serde(default)]
    pub response: Option<serde_json::Value>,
    /// HTTP status code Phoenix returned.
    #[serde(default)]
    pub status: u16,
    /// Server-side elapsed time in milliseconds (resolver + middleware
    /// time, excluding network).
    #[serde(default)]
    pub elapsed_ms: i64,
    /// Wall-clock timestamp Phoenix wrote this record.
    pub ts: DateTime<Utc>,
}

impl CaptureRecord {
    /// Convenience: return the operation name if known, otherwise
    /// `"<anonymous>"`. Used for logging and report grouping.
    pub fn operation_label(&self) -> &str {
        self.operation.as_deref().unwrap_or("<anonymous>")
    }

    /// True when Phoenix's response shape claims success (HTTP 2xx
    /// AND no top-level `errors` array).
    pub fn is_successful(&self) -> bool {
        if !(200..300).contains(&self.status) {
            return false;
        }
        let Some(resp) = &self.response else {
            return true;
        };
        let Some(obj) = resp.as_object() else {
            return true;
        };
        match obj.get("errors") {
            Some(serde_json::Value::Array(errs)) => errs.is_empty(),
            _ => true,
        }
    }
}

/// Outcome of reading a single line.
#[derive(Debug, thiserror::Error)]
pub enum CorpusError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("invalid JSONL at line {line}: {source}")]
    Decode {
        line: usize,
        #[source]
        source: serde_json::Error,
    },
}

/// Result of [`load_corpus`]. Encapsulates the records that did parse
/// plus a count of lines that failed so the caller can decide whether
/// to gate on the failure rate.
#[derive(Debug, Default)]
pub struct CorpusLoad {
    pub records: Vec<CaptureRecord>,
    pub skipped: Vec<SkippedLine>,
}

#[derive(Debug)]
pub struct SkippedLine {
    pub line: usize,
    pub reason: String,
}

/// Load every JSONL record from `path`. Malformed lines are tallied
/// in [`CorpusLoad::skipped`] but do not fail the load.
pub fn load_corpus(path: impl AsRef<Path>) -> Result<CorpusLoad, CorpusError> {
    let file = File::open(path.as_ref())?;
    load_corpus_from_reader(BufReader::new(file))
}

/// Lower-level variant — read from any `Read` source. Useful for
/// tests that feed in-memory bytes.
pub fn load_corpus_from_reader<R: Read>(reader: R) -> Result<CorpusLoad, CorpusError> {
    let buf = BufReader::new(reader);
    let mut load = CorpusLoad::default();

    for (idx, line) in buf.lines().enumerate() {
        let line_no = idx + 1;
        let raw = line?;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<CaptureRecord>(trimmed) {
            Ok(record) => load.records.push(record),
            Err(err) => load.skipped.push(SkippedLine {
                line: line_no,
                reason: err.to_string(),
            }),
        }
    }

    Ok(load)
}

/// Append a record to a JSONL file. Used by tests and any
/// Rust-side capture surface that may follow Phoenix's plug.
pub fn append_record(path: impl AsRef<Path>, record: &CaptureRecord) -> Result<(), CorpusError> {
    let mut file = File::options().create(true).append(true).open(path)?;
    let line = serde_json::to_string(record).map_err(|err| CorpusError::Decode {
        line: 0,
        source: err,
    })?;
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn sample_record() -> CaptureRecord {
        CaptureRecord {
            operation: Some("Movies".to_owned()),
            query: Some("query Movies { movies { id } }".to_owned()),
            variables: Some(serde_json::json!({"first": 20})),
            response: Some(serde_json::json!({"data": {"movies": []}})),
            status: 200,
            elapsed_ms: 17,
            ts: "2026-05-21T12:34:56Z".parse().unwrap(),
        }
    }

    #[test]
    fn round_trips_one_record() {
        let original = sample_record();
        let line = serde_json::to_string(&original).unwrap();
        let reader = Cursor::new(line.as_bytes());
        let load = load_corpus_from_reader(reader).unwrap();
        assert_eq!(load.records.len(), 1);
        assert_eq!(load.records[0], original);
        assert!(load.skipped.is_empty());
    }

    #[test]
    fn round_trips_multiple_records_with_blank_lines() {
        let r1 = sample_record();
        let mut r2 = sample_record();
        r2.operation = Some("Second".to_owned());
        let line1 = serde_json::to_string(&r1).unwrap();
        let line2 = serde_json::to_string(&r2).unwrap();
        let combined = format!("{line1}\n\n{line2}\n");

        let load = load_corpus_from_reader(Cursor::new(combined.as_bytes())).unwrap();
        assert_eq!(load.records.len(), 2);
        assert_eq!(load.records[0].operation.as_deref(), Some("Movies"));
        assert_eq!(load.records[1].operation.as_deref(), Some("Second"));
        assert!(load.skipped.is_empty());
    }

    #[test]
    fn malformed_line_does_not_abort() {
        let valid = serde_json::to_string(&sample_record()).unwrap();
        let body = format!("{valid}\nnot json\n{valid}\n");

        let load = load_corpus_from_reader(Cursor::new(body.as_bytes())).unwrap();
        assert_eq!(load.records.len(), 2);
        assert_eq!(load.skipped.len(), 1);
        assert_eq!(load.skipped[0].line, 2);
    }

    #[test]
    fn operation_label_falls_back_to_anonymous() {
        let mut r = sample_record();
        r.operation = None;
        assert_eq!(r.operation_label(), "<anonymous>");
    }

    #[test]
    fn is_successful_flags_top_level_errors() {
        let mut r = sample_record();
        r.response = Some(serde_json::json!({"errors": [{"message": "nope"}]}));
        assert!(!r.is_successful());

        r.response = Some(serde_json::json!({"errors": []}));
        assert!(r.is_successful());

        r.response = Some(serde_json::json!({"data": {"movies": []}}));
        assert!(r.is_successful());

        r.status = 500;
        assert!(!r.is_successful());
    }

    #[test]
    fn append_then_load_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("corpus.jsonl");

        let r1 = sample_record();
        let mut r2 = sample_record();
        r2.operation = Some("Second".to_owned());

        append_record(&path, &r1).unwrap();
        append_record(&path, &r2).unwrap();

        let load = load_corpus(&path).unwrap();
        assert_eq!(load.records.len(), 2);
        assert_eq!(load.records[0], r1);
        assert_eq!(load.records[1], r2);
    }

    #[test]
    fn decodes_phoenix_emitted_record() {
        // Pin compatibility with the byte shape the Phoenix plug
        // emits. Key order is implementation-defined; we don't pin
        // that — only the parsed structure.
        let phoenix_line = r#"{"ts":"2026-05-21T12:34:56Z","operation":"Movies","query":"query Movies { movies { id } }","variables":{"first":20},"status":200,"elapsed_ms":17,"response":{"data":{"movies":[]}}}"#;
        let record: CaptureRecord = serde_json::from_str(phoenix_line).unwrap();
        assert_eq!(record, sample_record());
    }

    #[test]
    fn decodes_unparseable_body_marker() {
        let phoenix_line = r#"{"ts":"2026-05-21T12:34:56Z","status":500,"elapsed_ms":2,"response":{"_unparseable_body":"Internal Server Error"}}"#;
        let record: CaptureRecord = serde_json::from_str(phoenix_line).unwrap();
        assert_eq!(record.status, 500);
        assert_eq!(
            record.response.as_ref().unwrap()["_unparseable_body"],
            "Internal Server Error"
        );
        assert!(!record.is_successful());
    }
}
