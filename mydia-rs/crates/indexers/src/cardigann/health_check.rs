//! Cardigann-specific health probes.
//!
//! Port of `lib/mydia/indexers/cardigann_health_check.ex`. Tests a
//! known-good search query against a parsed definition and returns a
//! [`HealthResult`].

use crate::cardigann::definition_parsed::ParsedDefinition;
use crate::cardigann::search_engine::{SearchEngine, SearchRequest};
use crate::error::IndexerError;
use crate::health::{HealthResult, HealthStatus};

/// Outcome of a health probe.
#[derive(Debug, Clone)]
pub struct ProbeOutcome {
    pub result: HealthResult,
    pub error: Option<IndexerError>,
}

/// Probe an indexer by running a trivial search (`"test"`) and counting
/// the rows returned. Empty results aren't necessarily a failure — some
/// indexers genuinely match nothing for this query — so the threshold
/// is "did parsing complete without an error".
pub async fn probe(
    engine: &SearchEngine,
    definition: &ParsedDefinition,
    base_url: &str,
) -> ProbeOutcome {
    let request = SearchRequest {
        keywords: Some("test".into()),
        ..SearchRequest::default()
    };

    match engine
        .execute(definition, base_url, &request, &definition.name)
        .await
    {
        Ok(results) => ProbeOutcome {
            result: HealthResult {
                status: HealthStatus::Healthy,
                checked_at: chrono::Utc::now(),
                details: serde_json::json!({ "row_count": results.len() }),
                error: None,
            },
            error: None,
        },
        Err(err) => ProbeOutcome {
            result: HealthResult::unhealthy(err.message.clone()),
            error: Some(err),
        },
    }
}
