//! Per-search session state.
//!
//! Port of `lib/mydia/indexers/cardigann_search_session.ex`. The
//! Phoenix schema stores one row per outbound search request for
//! debugging and rate-limit analysis. This Rust port carries the same
//! struct shape; persistence lives in the `db` crate and is wired up
//! in U17.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Record of a single search request — query + counts + timing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchSession {
    pub id: String,
    pub cardigann_definition_id: String,
    pub query: String,
    pub categories: Vec<i32>,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub status: SearchSessionStatus,
    pub result_count: u32,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchSessionStatus {
    Pending,
    InFlight,
    Completed,
    Failed,
}

impl SearchSession {
    /// Start a new in-flight session.
    #[must_use]
    pub fn start(
        id: impl Into<String>,
        cardigann_definition_id: impl Into<String>,
        query: impl Into<String>,
        categories: Vec<i32>,
    ) -> Self {
        Self {
            id: id.into(),
            cardigann_definition_id: cardigann_definition_id.into(),
            query: query.into(),
            categories,
            started_at: Utc::now(),
            completed_at: None,
            status: SearchSessionStatus::InFlight,
            result_count: 0,
            error_message: None,
        }
    }

    pub fn complete(&mut self, result_count: u32) {
        self.status = SearchSessionStatus::Completed;
        self.completed_at = Some(Utc::now());
        self.result_count = result_count;
    }

    pub fn fail(&mut self, message: impl Into<String>) {
        self.status = SearchSessionStatus::Failed;
        self.completed_at = Some(Utc::now());
        self.error_message = Some(message.into());
    }
}
