use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ImportSession")]
pub struct ImportSession {
    pub id: async_graphql::ID,
    pub step: String,
    pub status: String,
    pub scan_path: Option<String>,
    pub session_data: Option<String>,
    pub scan_stats: Option<String>,
    pub import_progress: Option<String>,
    pub import_results: Option<String>,
    pub completed_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

impl ImportSession {
    pub fn from_row(row: &mydia_rs_entities::import_sessions::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            step: row.step.clone(),
            status: row.status.clone(),
            scan_path: row.scan_path.clone(),
            session_data: row.session_data.clone(),
            scan_stats: row.scan_stats.clone(),
            import_progress: row.import_progress.clone(),
            import_results: row.import_results.clone(),
            completed_at: row.completed_at.as_ref().map(|t| t.0),
            expires_at: row.expires_at.as_ref().map(|t| t.0),
            inserted_at: row.inserted_at.0,
        })
    }
}
