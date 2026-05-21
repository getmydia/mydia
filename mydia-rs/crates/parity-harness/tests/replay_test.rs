//! U13 integration test — replay a small committed corpus against
//! the real mydia-rs schema and assert the report bucketing.
//!
//! The fixture corpus exercises four classes of outcomes:
//!
//! - `SchemaVersion` / `NodeType` / `NodeTypeInvalid` / `Ping` —
//!   DB-less operations that should match.
//! - `DownloadOptionsStub` — captured against a Phoenix that succeeded;
//!   mydia-rs returns the U14 "not implemented" error, so the harness
//!   classifies it as `UnexpectedError` (Phoenix succeeded, mydia-rs
//!   errored).
//!
//! That last one's a useful signal: the parity harness flags the gap
//! without aborting the run, and the report's `unexpected_errors`
//! count is the actionable bucket.

use std::path::PathBuf;

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::connect_from_config;
use mydia_rs_graphql::{build_schema, GraphqlAppState};
use mydia_rs_parity_harness::{load_corpus, replay_corpus, RedactionSet, ReplayOutcome, Report};

fn corpus_path() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("tests");
    path.push("fixtures");
    path.push("sample_corpus.jsonl");
    path
}

#[tokio::test]
async fn replay_against_committed_fixture() {
    let load = load_corpus(corpus_path()).expect("load corpus");
    assert!(load.skipped.is_empty(), "skipped lines: {:?}", load.skipped);
    assert_eq!(load.records.len(), 5);

    // In-memory SQLite — none of the fixture records touch the DB.
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(":memory:".to_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config(&config).await.expect("connect");
    let schema = build_schema(GraphqlAppState::new(db));

    // Redact the schemaVersion comparison — the corpus pinned "0.1.0"
    // and that should keep working as the crate version bumps.
    let extra = RedactionSet::new().redact("data.schemaVersion");
    let results = replay_corpus(&schema, &load.records, extra).await;
    let report = Report::from_results(&results);
    let totals = report.totals();

    // 4 match outright; DownloadOptionsStub surfaces as `not_implemented`
    // because mydia-rs emits a "Downloads not implemented yet" error
    // that the classifier recognizes — Phoenix returned a stub list,
    // but the harness deliberately distinguishes deliberate stubs
    // from regressions.
    assert_eq!(totals.matches, 4, "totals: {:?}", totals);
    assert_eq!(totals.not_implemented, 1);
    assert_eq!(totals.unexpected_errors, 0);
    assert_eq!(totals.mismatches, 0);

    // Each operation has its own bucket.
    let download_bucket = report
        .per_operation
        .get("DownloadOptionsStub")
        .expect("bucket");
    assert_eq!(download_bucket.not_implemented, 1);

    // Coverage gaps should include DownloadOptionsStub (no matches
    // for that operation).
    let gaps = report.coverage_gaps();
    assert!(gaps.contains(&"DownloadOptionsStub"));
    assert!(!gaps.contains(&"SchemaVersion"));
}

#[tokio::test]
async fn replay_classifies_not_implemented_separately_when_message_matches() {
    use mydia_rs_parity_harness::CaptureRecord;

    // `downloadOptions` is unauthenticated — going straight to the
    // U14 stub branch — and emits the "Downloads not implemented yet"
    // error the classifier looks for.
    let record = CaptureRecord {
        operation: Some("DownloadOptionsStub".into()),
        query: Some(
            r#"mutation { downloadOptions(contentType: "movie", id: "x") { resolution } }"#.into(),
        ),
        variables: None,
        response: Some(serde_json::json!({
            "data": {"downloadOptions": []},
            "errors": []
        })),
        status: 200,
        elapsed_ms: 1,
        ts: chrono::Utc::now(),
    };
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(":memory:".to_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config(&config).await.expect("connect");
    let schema = build_schema(GraphqlAppState::new(db));
    let results = replay_corpus(&schema, std::slice::from_ref(&record), RedactionSet::new()).await;
    let result = &results[0];
    assert!(
        matches!(result.outcome, ReplayOutcome::NotImplemented { .. }),
        "outcome: {:?}",
        result.outcome
    );
}

#[tokio::test]
async fn replay_reports_drift_when_responses_differ() {
    use mydia_rs_parity_harness::CaptureRecord;

    let record = CaptureRecord {
        operation: Some("NodeType".into()),
        query: Some("{ nodeType(id: \"movie:abc\") }".into()),
        variables: None,
        response: Some(serde_json::json!({
            "data": {"nodeType": "different-tag"},
            "errors": []
        })),
        status: 200,
        elapsed_ms: 1,
        ts: chrono::Utc::now(),
    };
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(":memory:".to_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config(&config).await.expect("connect");
    let schema = build_schema(GraphqlAppState::new(db));
    let results = replay_corpus(&schema, std::slice::from_ref(&record), RedactionSet::new()).await;
    let result = &results[0];
    let diffs = match &result.outcome {
        ReplayOutcome::Mismatch { diffs } => diffs,
        other => panic!("expected mismatch, got {other:?}"),
    };
    assert!(!diffs.is_empty());
    let paths: Vec<&str> = diffs.iter().map(|d| d.path.as_str()).collect();
    assert!(
        paths.iter().any(|p| p.contains("nodeType")),
        "paths: {paths:?}"
    );
}
