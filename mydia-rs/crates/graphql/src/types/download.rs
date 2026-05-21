//! Download-related GraphQL types — ports of
//! `common_types.ex:230-272`.
//!
//! Real DB-backed resolvers ship with U20 (downloads pipeline). U14
//! lands the type shapes so the SDL contract matches Phoenix and the
//! parity replay harness can flag the mutations as `not-implemented`
//! consistently.

use async_graphql::{SimpleObject, ID};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DownloadOption")]
pub struct DownloadOption {
    pub resolution: String,
    pub label: String,
    pub estimated_size: i64,
    pub transcode_status: Option<String>,
    pub transcode_progress: Option<f64>,
    pub actual_size: Option<i64>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "PrepareDownloadResult")]
pub struct PrepareDownloadResult {
    pub job_id: ID,
    pub status: String,
    pub progress: f64,
    pub file_size: Option<i64>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DownloadJobStatus")]
pub struct DownloadJobStatus {
    pub job_id: ID,
    pub status: String,
    pub progress: f64,
    pub error: Option<String>,
    pub file_size: Option<i64>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "CancelDownloadResult")]
pub struct CancelDownloadResult {
    pub success: bool,
}
