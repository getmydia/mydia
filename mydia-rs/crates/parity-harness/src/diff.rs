//! JSON diff with redaction rules.
//!
//! U13 replays each captured record against the mydia-rs schema and
//! compares the two responses. Strict equality is too strict: every
//! captured response carries timestamps, ephemeral session IDs, and
//! signed media URLs that are deliberately non-deterministic. The
//! [`RedactionSet`] here masks those leaf values to a stable sentinel
//! before comparing.
//!
//! Redaction is applied independently to both sides of the diff, so
//! the result is "do these responses match after redacting volatile
//! leaves?" — not "does the right side have anything in place of a
//! redacted leaf on the left side."
//!
//! Field paths use JSON Pointer-ish dotted notation but support `*`
//! wildcards for array indices and unknown keys:
//!
//! - `data.movies.*.inserted_at` — every movie row's `inserted_at`
//! - `data.*.last_activity_at` — any top-level field with that suffix
//! - `data.streamingSession.session_id` — exact path
//!
//! Wildcards are not regex; they match a single segment.

use serde_json::Value;

const REDACTED: &str = "<redacted>";

/// Set of dotted paths whose leaf values should be replaced with
/// [`REDACTED`] before comparison.
#[derive(Debug, Default, Clone)]
pub struct RedactionSet {
    paths: Vec<Vec<Segment>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Segment {
    Wildcard,
    Key(String),
}

impl Segment {
    fn matches(&self, key: &str) -> bool {
        match self {
            Segment::Wildcard => true,
            Segment::Key(k) => k == key,
        }
    }
}

impl RedactionSet {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a dotted path to the redaction set. Wildcards (`*`) match
    /// a single segment.
    pub fn redact(mut self, path: &str) -> Self {
        let segments = path
            .split('.')
            .map(|seg| {
                if seg == "*" {
                    Segment::Wildcard
                } else {
                    Segment::Key(seg.to_owned())
                }
            })
            .collect();
        self.paths.push(segments);
        self
    }

    /// Common set of redactions for mydia GraphQL responses. Mirrors
    /// the U9/U13 plan's named volatile fields: timestamps, ephemeral
    /// session IDs, signed media URLs. Add more as the parity
    /// harness surfaces them.
    pub fn defaults() -> Self {
        Self::new()
            .redact("data.*.inserted_at")
            .redact("data.*.updated_at")
            .redact("data.*.last_activity_at")
            .redact("data.*.last_used_at")
            .redact("data.*.last_seen_at")
            .redact("data.*.last_scan_at")
            .redact("data.*.expires_at")
            .redact("data.*.created_at")
            .redact("data.*.streamUrl")
            .redact("data.*.directPlayUrl")
            .redact("data.*.thumbnailUrl")
            .redact("data.*.posterUrl")
            .redact("data.*.backdropUrl")
            .redact("data.startStreamingSession.sessionId")
            // Walk one level deeper into connections (edges/node).
            .redact("data.*.edges.*.node.inserted_at")
            .redact("data.*.edges.*.node.updated_at")
            .redact("data.*.edges.*.node.streamUrl")
            .redact("data.*.edges.*.node.directPlayUrl")
            .redact("data.*.edges.*.node.thumbnailUrl")
            .redact("data.*.edges.*.node.posterUrl")
    }

    /// Walk `value` and replace leaves whose path matches any
    /// registered pattern with the sentinel.
    pub fn apply(&self, value: &mut Value) {
        for path in &self.paths {
            apply_path(value, path);
        }
    }
}

fn apply_path(value: &mut Value, path: &[Segment]) {
    if path.is_empty() {
        return;
    }
    apply_walk(value, path);
}

fn apply_walk(value: &mut Value, path: &[Segment]) {
    let Some((head, rest)) = path.split_first() else {
        return;
    };

    match value {
        Value::Object(map) => {
            let keys: Vec<String> = map
                .iter()
                .filter(|(k, _)| head.matches(k))
                .map(|(k, _)| k.clone())
                .collect();
            for key in keys {
                if let Some(child) = map.get_mut(&key) {
                    if rest.is_empty() {
                        *child = Value::String(REDACTED.to_owned());
                    } else {
                        apply_walk(child, rest);
                    }
                }
            }
        }
        Value::Array(arr) => {
            // Array indices match the wildcard segment; numeric keys
            // are not supported (Absinthe doesn't number array
            // children at the path-string level).
            if matches!(head, Segment::Wildcard) {
                for child in arr.iter_mut() {
                    if rest.is_empty() {
                        *child = Value::String(REDACTED.to_owned());
                    } else {
                        apply_walk(child, rest);
                    }
                }
            }
        }
        _ => {}
    }
}

/// One element of a diff.
#[derive(Debug, Clone, PartialEq)]
pub struct DiffEntry {
    pub path: String,
    pub left: Value,
    pub right: Value,
}

/// Compare two JSON values after applying the redaction set. Returns
/// an empty Vec when they match, otherwise a list of mismatches.
pub fn diff(redactions: &RedactionSet, left: &Value, right: &Value) -> Vec<DiffEntry> {
    let mut left = left.clone();
    let mut right = right.clone();
    redactions.apply(&mut left);
    redactions.apply(&mut right);

    let mut out = Vec::new();
    collect(&mut out, "", &left, &right);
    out
}

fn collect(out: &mut Vec<DiffEntry>, path: &str, left: &Value, right: &Value) {
    match (left, right) {
        (Value::Object(l), Value::Object(r)) => {
            let mut keys: Vec<&String> = l.keys().chain(r.keys()).collect();
            keys.sort();
            keys.dedup();
            for key in keys {
                let child_path = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                };
                match (l.get(key), r.get(key)) {
                    (Some(lv), Some(rv)) => collect(out, &child_path, lv, rv),
                    (Some(lv), None) => out.push(DiffEntry {
                        path: child_path,
                        left: lv.clone(),
                        right: Value::Null,
                    }),
                    (None, Some(rv)) => out.push(DiffEntry {
                        path: child_path,
                        left: Value::Null,
                        right: rv.clone(),
                    }),
                    (None, None) => {}
                }
            }
        }
        (Value::Array(l), Value::Array(r)) => {
            let len = l.len().max(r.len());
            for i in 0..len {
                let child_path = format!("{path}[{i}]");
                match (l.get(i), r.get(i)) {
                    (Some(lv), Some(rv)) => collect(out, &child_path, lv, rv),
                    (Some(lv), None) => out.push(DiffEntry {
                        path: child_path,
                        left: lv.clone(),
                        right: Value::Null,
                    }),
                    (None, Some(rv)) => out.push(DiffEntry {
                        path: child_path,
                        left: Value::Null,
                        right: rv.clone(),
                    }),
                    (None, None) => {}
                }
            }
        }
        (l, r) if l == r => {}
        (l, r) => out.push(DiffEntry {
            path: path.to_owned(),
            left: l.clone(),
            right: r.clone(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn identical_objects_match() {
        let left = json!({"data": {"movies": []}});
        let right = json!({"data": {"movies": []}});
        assert!(diff(&RedactionSet::new(), &left, &right).is_empty());
    }

    #[test]
    fn mismatched_scalar_reports_path() {
        let left = json!({"data": {"count": 1}});
        let right = json!({"data": {"count": 2}});
        let entries = diff(&RedactionSet::new(), &left, &right);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "data.count");
    }

    #[test]
    fn missing_right_side_key_reports_diff() {
        let left = json!({"data": {"a": 1, "b": 2}});
        let right = json!({"data": {"a": 1}});
        let entries = diff(&RedactionSet::new(), &left, &right);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "data.b");
    }

    #[test]
    fn extra_right_side_key_reports_diff() {
        let left = json!({"data": {"a": 1}});
        let right = json!({"data": {"a": 1, "extra": "value"}});
        let entries = diff(&RedactionSet::new(), &left, &right);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "data.extra");
    }

    #[test]
    fn redacts_top_level_path() {
        let mut value = json!({"data": {"movies": [{"inserted_at": "2026-01-01T00:00:00Z"}]}});
        let redactions = RedactionSet::new().redact("data.movies.*.inserted_at");
        redactions.apply(&mut value);
        assert_eq!(value["data"]["movies"][0]["inserted_at"], "<redacted>");
    }

    #[test]
    fn timestamp_difference_is_masked_by_default_redactions() {
        let left = json!({
            "data": {
                "user": {"id": "abc", "inserted_at": "2026-01-01T00:00:00Z"}
            }
        });
        let right = json!({
            "data": {
                "user": {"id": "abc", "inserted_at": "2026-12-31T23:59:59Z"}
            }
        });
        let entries = diff(&RedactionSet::defaults(), &left, &right);
        assert!(entries.is_empty(), "expected match, got {entries:?}");
    }

    #[test]
    fn non_timestamp_difference_still_reports() {
        let left = json!({
            "data": {
                "user": {"id": "abc", "inserted_at": "2026-01-01T00:00:00Z"}
            }
        });
        let right = json!({
            "data": {
                "user": {"id": "DIFFERENT", "inserted_at": "2026-12-31T23:59:59Z"}
            }
        });
        let entries = diff(&RedactionSet::defaults(), &left, &right);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "data.user.id");
    }

    #[test]
    fn redacts_inside_relay_connection_edges() {
        let left = json!({
            "data": {
                "movies": {
                    "edges": [
                        {"node": {"id": "1", "streamUrl": "/api/v1/stream/AAA"}},
                        {"node": {"id": "2", "streamUrl": "/api/v1/stream/BBB"}}
                    ]
                }
            }
        });
        let right = json!({
            "data": {
                "movies": {
                    "edges": [
                        {"node": {"id": "1", "streamUrl": "/api/v1/stream/ZZZ"}},
                        {"node": {"id": "2", "streamUrl": "/api/v1/stream/YYY"}}
                    ]
                }
            }
        });
        let entries = diff(&RedactionSet::defaults(), &left, &right);
        assert!(entries.is_empty(), "expected match, got {entries:?}");
    }

    #[test]
    fn array_order_matters() {
        let left = json!({"data": {"items": [1, 2, 3]}});
        let right = json!({"data": {"items": [3, 2, 1]}});
        let entries = diff(&RedactionSet::new(), &left, &right);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "data.items[0]");
        assert_eq!(entries[1].path, "data.items[2]");
    }
}
