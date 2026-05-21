#![allow(clippy::doc_markdown)]

//! Integration tests for the indexers crate.
//!
//! Exercises the Cardigann engine end-to-end against real YAML
//! definitions (eztv, nyaasi) and the rate limiter / FlareSolverr
//! fallback paths via wiremock.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use mydia_rs_indexers::adapter::{
    AdapterConfig, AdapterKind, Capabilities, ConnectionInfo, IndexerAdapter, SearchOpts,
};
use mydia_rs_indexers::cardigann::parser::parse_definition;
use mydia_rs_indexers::cardigann::result_parser::{self, HttpResponse, ResponseType};
use mydia_rs_indexers::cardigann::search_engine::{SearchEngine, SearchRequest};
use mydia_rs_indexers::error::IndexerError;
use mydia_rs_indexers::flaresolverr::{FlareSolverr, FlareSolverrConfig, RequestOpts};
use mydia_rs_indexers::rate_limiter::{RateLimitOutcome, RateLimiter};
use mydia_rs_indexers::registry::IndexerRegistry;
use mydia_rs_indexers::search_result::SearchResult;

use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const EZTV_YAML: &str = include_str!("fixtures/eztv.yml");
const NYAASI_YAML: &str = include_str!("fixtures/nyaasi.yml");
const LIMETORRENTS_YAML: &str = include_str!("fixtures/limetorrents.yml");
const LIMETORRENTS_HTML: &str = include_str!("fixtures/limetorrents_response.html");

#[test]
fn parses_eztv_definition() {
    let parsed = parse_definition(EZTV_YAML).expect("eztv parses");
    assert_eq!(parsed.id, "eztv");
    assert_eq!(parsed.r#type, "public");
    assert!(parsed.search.fields.contains_key("title"));
    assert!(parsed.search.fields.contains_key("seeders"));
    // EZTV uses a single keyword-conditional path.
    assert_eq!(parsed.search.paths.len(), 1);
}

#[test]
fn parses_nyaasi_definition_with_category_mappings() {
    let parsed = parse_definition(NYAASI_YAML).expect("nyaasi parses");
    assert_eq!(parsed.id, "nyaasi");
    let mappings = &parsed.capabilities.categorymappings;
    assert!(!mappings.is_empty());
    let first = &mappings[0];
    assert_eq!(first["cat"], "TV/Anime");
}

#[test]
fn detects_response_type_for_real_html() {
    assert_eq!(
        result_parser::detect_response_type(LIMETORRENTS_HTML),
        ResponseType::Html
    );
}

#[test]
fn limetorrents_html_parses_search_results() {
    let parsed = parse_definition(LIMETORRENTS_YAML).expect("limetorrents parses");
    let response = HttpResponse {
        status: 200,
        body: LIMETORRENTS_HTML.into(),
        content_type: Some("text/html".into()),
    };
    let results = result_parser::parse_results(
        &parsed,
        &response,
        "LimeTorrents",
        "https://limetorrents.example",
    )
    .expect("parse ok");
    assert!(
        !results.is_empty(),
        "expected at least one row out of the limetorrents response"
    );
    for r in &results {
        assert!(!r.title.is_empty(), "every row needs a title");
    }
}

#[tokio::test]
async fn rate_limiter_throttles_above_limit() {
    let rl = RateLimiter::new();
    // 2 requests are allowed in a 60s window; third is throttled.
    for _ in 0..2 {
        assert_eq!(rl.check("eztv", Some(2)).await, RateLimitOutcome::Ok);
        rl.record("eztv").await;
    }
    match rl.check("eztv", Some(2)).await {
        RateLimitOutcome::Limited { retry_after_ms } => assert!(retry_after_ms > 0),
        RateLimitOutcome::Ok => panic!("expected limited"),
    }
}

#[tokio::test]
async fn flaresolverr_timeout_returns_timeout_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_millis(500))
                .set_body_json(serde_json::json!({"status": "ok"})),
        )
        .mount(&server)
        .await;

    let fs = FlareSolverr::new(FlareSolverrConfig {
        enabled: true,
        url: server.uri(),
        timeout_ms: 50,
        max_timeout_ms: 5_000,
    })
    .expect("flaresolverr init");
    let err = fs
        .get("https://example.com", &RequestOpts::default())
        .await
        .expect_err("must timeout");
    assert_eq!(err.kind, mydia_rs_indexers::ErrorKind::Timeout);
}

#[tokio::test]
async fn registry_dispatches_to_registered_adapter() {
    struct StubAdapter;

    #[async_trait]
    impl IndexerAdapter for StubAdapter {
        async fn test_connection(
            &self,
            _config: &AdapterConfig,
        ) -> Result<ConnectionInfo, IndexerError> {
            Ok(ConnectionInfo {
                name: Some("stub".into()),
                version: Some("0.0.0".into()),
                details: serde_json::Value::Null,
            })
        }
        async fn search(
            &self,
            _config: &AdapterConfig,
            _query: &str,
            _opts: &SearchOpts,
        ) -> Result<Vec<SearchResult>, IndexerError> {
            Ok(Vec::new())
        }
        async fn capabilities(
            &self,
            _config: &AdapterConfig,
        ) -> Result<Capabilities, IndexerError> {
            Ok(Capabilities::default())
        }
    }

    let registry = IndexerRegistry::new();
    registry.register(AdapterKind::Cardigann, Arc::new(StubAdapter));
    let adapter = registry
        .adapter(AdapterKind::Cardigann)
        .expect("registered");

    let config = AdapterConfig {
        r#type: AdapterKind::Cardigann,
        name: "stub".into(),
        base_url: "https://stub".into(),
        api_key: None,
        options: serde_json::Value::Null,
        id: "stub-1".into(),
        rate_limit: None,
    };
    let info = adapter.test_connection(&config).await.unwrap();
    assert_eq!(info.name.as_deref(), Some("stub"));
}

#[tokio::test]
async fn cardigann_search_against_wiremock_returns_results() {
    let parsed = parse_definition(LIMETORRENTS_YAML).unwrap();
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string(LIMETORRENTS_HTML))
        .mount(&server)
        .await;

    let engine = SearchEngine::new().unwrap();
    let request = SearchRequest {
        keywords: Some("ubuntu".into()),
        config: serde_json::json!({
            "downloadlink": "magnet:",
            "downloadlink2": "http://itorrents.org/",
            "sort": "seeds",
        }),
        ..SearchRequest::default()
    };
    let results = engine
        .execute(&parsed, &server.uri(), &request, "LimeTorrents")
        .await
        .expect("search ok");
    assert!(!results.is_empty(), "expected at least one parsed row");
}
