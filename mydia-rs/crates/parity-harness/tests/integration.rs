//! U9 integration test — pin the cross-boundary contract.
//!
//! Synthesises a JSONL corpus matching the byte shape Phoenix's
//! `MydiaWeb.Plugs.ParityCapture` emits, loads it through the Rust
//! reader, and runs the diff over a stub mydia-rs response. Confirms
//! the redaction set produces "equivalent" on byte-different but
//! semantically-identical responses — the load-bearing property the
//! U13 replay harness relies on.

use mydia_rs_parity_harness::{diff, load_corpus, RedactionSet};
use serde_json::json;

#[test]
fn phoenix_corpus_replays_against_stub_response() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("capture.jsonl");

    // Two captured records — one Movies query, one Streaming start.
    let movies_line = serde_json::to_string(&json!({
        "ts": "2026-05-21T12:34:56Z",
        "operation": "Movies",
        "query": "query Movies { movies(first: 1) { edges { node { id title streamUrl } } } }",
        "variables": null,
        "status": 200,
        "elapsed_ms": 12,
        "response": {
            "data": {
                "movies": {
                    "edges": [
                        {"node": {
                            "id": "movie:42",
                            "title": "Inception",
                            "streamUrl": "/api/v1/stream/PHOENIX-TOKEN"
                        }}
                    ]
                }
            }
        }
    }))
    .unwrap();

    let stream_line = serde_json::to_string(&json!({
        "ts": "2026-05-21T12:34:58Z",
        "operation": "StartStream",
        "query": "mutation StartStream { startStreamingSession(mediaFileId: \"f1\") { sessionId duration } }",
        "variables": null,
        "status": 200,
        "elapsed_ms": 19,
        "response": {
            "data": {
                "startStreamingSession": {
                    "sessionId": "phoenix-session-abc",
                    "duration": 7200
                }
            }
        }
    }))
    .unwrap();

    std::fs::write(&path, format!("{movies_line}\n{stream_line}\n")).unwrap();

    let load = load_corpus(&path).unwrap();
    assert_eq!(load.records.len(), 2);
    assert!(load.skipped.is_empty());

    let movies = &load.records[0];
    let stream = &load.records[1];

    // Build a stub mydia-rs response that diverges only on the
    // volatile fields (streamUrl, sessionId) — exactly the shape U13
    // will see when it replays a query whose response differs only
    // on ephemeral data.
    let mydia_rs_movies = json!({
        "data": {
            "movies": {
                "edges": [
                    {"node": {
                        "id": "movie:42",
                        "title": "Inception",
                        "streamUrl": "/api/v1/stream/RUST-TOKEN"
                    }}
                ]
            }
        }
    });

    let mydia_rs_stream = json!({
        "data": {
            "startStreamingSession": {
                "sessionId": "rust-session-xyz",
                "duration": 7200
            }
        }
    });

    let redactions = RedactionSet::defaults();
    let movies_diff = diff(
        &redactions,
        movies.response.as_ref().unwrap(),
        &mydia_rs_movies,
    );
    let stream_diff = diff(
        &redactions,
        stream.response.as_ref().unwrap(),
        &mydia_rs_stream,
    );

    assert!(
        movies_diff.is_empty(),
        "expected redacted streamUrl to mask the difference; got {movies_diff:?}"
    );
    assert!(
        stream_diff.is_empty(),
        "expected redacted sessionId to mask the difference; got {stream_diff:?}"
    );
}

#[test]
fn real_semantic_drift_still_reports_diff() {
    // Same corpus shape, but mydia-rs returns the wrong title.
    let phoenix = json!({
        "data": {
            "movies": {
                "edges": [
                    {"node": {
                        "id": "movie:42",
                        "title": "Inception",
                        "streamUrl": "/api/v1/stream/X"
                    }}
                ]
            }
        }
    });
    let rust = json!({
        "data": {
            "movies": {
                "edges": [
                    {"node": {
                        "id": "movie:42",
                        "title": "Interstellar",
                        "streamUrl": "/api/v1/stream/Y"
                    }}
                ]
            }
        }
    });

    let entries = diff(&RedactionSet::defaults(), &phoenix, &rust);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "data.movies.edges[0].node.title");
}
