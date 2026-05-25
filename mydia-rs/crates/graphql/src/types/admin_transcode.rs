use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "TranscodeJob")]
pub struct TranscodeJob {
    pub id: ID,
    pub media_file_id: String,
    pub resolution: String,
    pub status: String,
    pub progress: Option<f64>,
    pub output_path: Option<String>,
    pub file_size: Option<i32>,
    pub error: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub r#type: String,
    pub user_id: Option<String>,
}

impl TranscodeJob {
    pub fn from_row(row: &mydia_rs_entities::transcode_jobs::Model) -> Self {
        Self {
            id: ID(row.id.0.to_string()),
            media_file_id: row.media_file_id.0.to_string(),
            resolution: row.resolution.clone(),
            status: row.status.clone(),
            progress: row.progress,
            output_path: row.output_path.clone(),
            file_size: row.file_size,
            error: row.error.clone(),
            started_at: row.started_at.map(|t| t.0),
            completed_at: row.completed_at.map(|t| t.0),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
            r#type: row.r#type.clone(),
            user_id: row.user_id.as_ref().map(|u| u.0.to_string()),
        }
    }
}
