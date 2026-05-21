//! `CardigannDefinition` schema struct.
//!
//! Port of `lib/mydia/indexers/cardigann_definition.ex`. Stored in the
//! `cardigann_definitions` table — the U5 `db` crate owns the actual
//! row schema; this struct mirrors the column layout so resolvers and
//! workers can share one type.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Indexer type discriminant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum IndexerType {
    Public,
    Private,
    #[serde(rename = "semi-private")]
    SemiPrivate,
}

/// Health discriminant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatusCode {
    Healthy,
    Degraded,
    Unhealthy,
    Unknown,
}

/// One row of `cardigann_definitions`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardigannDefinitionRow {
    pub id: String,
    pub indexer_id: String,
    pub name: String,
    pub description: Option<String>,
    pub language: Option<String>,
    pub r#type: IndexerType,
    pub encoding: Option<String>,
    pub links: serde_json::Value,
    pub capabilities: serde_json::Value,
    /// Raw YAML — parsed lazily via [`crate::cardigann::parser::parse_definition`].
    pub definition: String,
    pub schema_version: String,
    #[serde(default)]
    pub enabled: bool,
    pub config: Option<serde_json::Value>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub health_status: HealthStatusCode,
    pub last_health_check_at: Option<DateTime<Utc>>,
    pub last_successful_query_at: Option<DateTime<Utc>>,
    pub consecutive_failures: u32,
    #[serde(default)]
    pub flaresolverr_required: bool,
    #[serde(default)]
    pub flaresolverr_enabled: bool,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl CardigannDefinitionRow {
    /// Whether FlareSolverr should be consulted for this indexer.
    ///
    /// Mirrors `use_flaresolverr?/1`: required + (enabled OR unset).
    #[must_use]
    pub fn use_flaresolverr(&self) -> bool {
        self.flaresolverr_required && self.flaresolverr_enabled
    }
}
