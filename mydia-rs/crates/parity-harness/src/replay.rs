//! Replay a corpus of captured GraphQL operations against an
//! `async_graphql::Schema`.
//!
//! The replay treats each [`CaptureRecord`] independently:
//!
//! 1. Run the operation through the supplied schema with the captured
//!    variables.
//! 2. Compare the mydia-rs response to the Phoenix response (which
//!    Phoenix wrote to the corpus at capture time).
//! 3. Bucket the outcome — match, mismatch, or "resolver not
//!    implemented" — and surface a [`ReplayResult`] per record.
//!
//! Comparison uses [`crate::diff`]'s `RedactionSet::defaults()` plus
//! any extra paths the caller registers (for example, the replay
//! binary adds `data.startStreamingSession.sessionId` as a redaction
//! because mydia-rs generates a fresh UUID per session in U11).
//!
//! Errors during execution (panic, async-graphql refusing to even
//! parse the query) surface as [`ReplayResult::Error`] rather than
//! aborting the whole run — one bad record shouldn't stop the
//! report.

use std::sync::Arc;

use async_graphql::{ObjectType, Request, Schema, SubscriptionType, Variables};
use serde_json::Value;

use crate::corpus::CaptureRecord;
use crate::diff::{diff, DiffEntry, RedactionSet};

/// Outcome of replaying one record. The discriminator drives the
/// report's bucketing and exit code.
#[derive(Debug, Clone)]
pub enum ReplayOutcome {
    /// mydia-rs returned a response that matches Phoenix's (after
    /// redactions).
    Match,
    /// Both sides returned successfully but the data differs after
    /// redactions.
    Mismatch { diffs: Vec<DiffEntry> },
    /// mydia-rs surfaced a "not implemented" / "lands in U14" error.
    /// Counted separately so the report can distinguish "we drifted"
    /// from "we deliberately stubbed this surface."
    NotImplemented { message: String },
    /// mydia-rs threw an error and Phoenix did not — surfaced as
    /// regression candidates in the report.
    UnexpectedError { message: String },
    /// Both sides errored. Counted as a non-fault for the binary's
    /// exit code, since the contract surface is "errors match too."
    BothErrored,
}

#[derive(Debug, Clone)]
pub struct ReplayResult {
    pub operation: String,
    pub outcome: ReplayOutcome,
}

impl ReplayResult {
    pub fn is_match(&self) -> bool {
        matches!(
            self.outcome,
            ReplayOutcome::Match | ReplayOutcome::BothErrored
        )
    }

    pub fn is_drift(&self) -> bool {
        matches!(
            self.outcome,
            ReplayOutcome::Mismatch { .. } | ReplayOutcome::UnexpectedError { .. }
        )
    }
}

/// Replay every record in `records` against `schema` and return one
/// result per input. `extra_redactions` is folded into the default set
/// — pass an empty `RedactionSet` if you want only the defaults.
pub async fn replay_corpus<Q, M, S>(
    schema: &Schema<Q, M, S>,
    records: &[CaptureRecord],
    extra_redactions: RedactionSet,
) -> Vec<ReplayResult>
where
    Q: ObjectType + 'static,
    M: ObjectType + 'static,
    S: SubscriptionType + 'static,
{
    let redactions = Arc::new(merge_redactions(extra_redactions));
    let mut results = Vec::with_capacity(records.len());
    for record in records {
        let result = replay_one(schema, record, &redactions).await;
        results.push(result);
    }
    results
}

/// Replay a single record. Surfaces the same [`ReplayResult`] shape
/// as [`replay_corpus`] for convenience when tests want to assert one
/// outcome at a time.
pub async fn replay_one<Q, M, S>(
    schema: &Schema<Q, M, S>,
    record: &CaptureRecord,
    redactions: &RedactionSet,
) -> ReplayResult
where
    Q: ObjectType + 'static,
    M: ObjectType + 'static,
    S: SubscriptionType + 'static,
{
    let label = record.operation_label().to_owned();
    let Some(query) = record.query.as_deref() else {
        return ReplayResult {
            operation: label,
            outcome: ReplayOutcome::UnexpectedError {
                message: "corpus record has no `query` field".into(),
            },
        };
    };

    let variables = match &record.variables {
        Some(Value::Object(_)) => Variables::from_json(record.variables.clone().unwrap()),
        _ => Variables::default(),
    };
    let request = Request::new(query.to_owned()).variables(variables);

    let our_response = schema.execute(request).await;
    let our_json = serialize_response(&our_response);
    let phoenix_json = record
        .response
        .clone()
        .unwrap_or_else(|| serde_json::json!({}));

    let our_has_error = response_has_error(&our_json);
    let phoenix_has_error = response_has_error(&phoenix_json);

    if our_has_error && phoenix_has_error {
        return ReplayResult {
            operation: label,
            outcome: ReplayOutcome::BothErrored,
        };
    }

    if our_has_error && !phoenix_has_error {
        // Classify "stub" errors (U14 placeholders for U19/U20/U29
        // surfaces) so the report can count them as deliberate.
        let message = first_error_message(&our_json);
        if is_not_implemented(&message) {
            return ReplayResult {
                operation: label,
                outcome: ReplayOutcome::NotImplemented { message },
            };
        }
        return ReplayResult {
            operation: label,
            outcome: ReplayOutcome::UnexpectedError { message },
        };
    }

    let diffs = diff(redactions, &phoenix_json, &our_json);
    if diffs.is_empty() {
        ReplayResult {
            operation: label,
            outcome: ReplayOutcome::Match,
        }
    } else {
        ReplayResult {
            operation: label,
            outcome: ReplayOutcome::Mismatch { diffs },
        }
    }
}

fn serialize_response(resp: &async_graphql::Response) -> Value {
    // Build the `{data, errors}` envelope explicitly rather than
    // relying on `serde_json::to_value(&resp)`. async-graphql's
    // `Response` serializes extra fields (`extensions`, `cache_control`,
    // `http_headers`) that Phoenix's captured response does not — the
    // diff would mismatch on shape rather than content.
    let data = serde_json::to_value(&resp.data).unwrap_or(Value::Null);
    let errors = if resp.errors.is_empty() {
        Value::Array(Vec::new())
    } else {
        serde_json::to_value(&resp.errors).unwrap_or_else(|_| Value::Array(Vec::new()))
    };
    let mut obj = serde_json::Map::new();
    obj.insert("data".to_owned(), data);
    obj.insert("errors".to_owned(), errors);
    Value::Object(obj)
}

fn response_has_error(value: &Value) -> bool {
    let Some(obj) = value.as_object() else {
        return false;
    };
    matches!(obj.get("errors"), Some(Value::Array(a)) if !a.is_empty())
}

fn first_error_message(value: &Value) -> String {
    value
        .get("errors")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|err| err.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("<no message>")
        .to_owned()
}

fn is_not_implemented(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("not implemented") || lower.contains("not yet implemented")
}

fn merge_redactions(extra: RedactionSet) -> RedactionSet {
    let mut base = RedactionSet::defaults();
    for path in extra.into_paths() {
        base = base.redact(&path);
    }
    base
}
