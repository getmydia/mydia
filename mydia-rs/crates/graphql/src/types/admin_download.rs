use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};
use mydia_rs_db::types::UuidText;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DownloadRecord")]
pub struct DownloadRecord {
    pub id: ID,
    pub title: String,
    pub indexer: Option<String>,
    pub download_url: Option<String>,
    pub download_client: Option<String>,
    pub match_status: Option<String>,
    pub error_message: Option<String>,
    pub completed_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub bytes_pulled: Option<i64>,
    pub last_known_bytes: Option<i32>,
    pub import_retry_count: Option<i32>,
    pub import_last_error: Option<String>,
    pub import_next_retry_at: Option<DateTime<Utc>>,
    pub import_failed_at: Option<DateTime<Utc>>,
    pub imported_at: Option<DateTime<Utc>>,
    pub media_item_id: Option<String>,
    pub episode_id: Option<String>,
    pub library_path_id: Option<String>,
}

impl DownloadRecord {
    pub fn from_row(row: &mydia_rs_entities::downloads::Model) -> Self {
        fn uuid_str(id: Option<&UuidText>) -> Option<String> {
            id.map(|u| u.0.to_string())
        }

        Self {
            id: ID(row.id.0.to_string()),
            title: row.title.clone(),
            indexer: row.indexer.clone(),
            download_url: row.download_url.clone(),
            download_client: row.download_client.clone(),
            match_status: row.match_status.clone(),
            error_message: row.error_message.clone(),
            completed_at: row.completed_at.map(|t| t.0),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
            bytes_pulled: row.bytes_pulled,
            last_known_bytes: row.last_known_bytes,
            import_retry_count: row.import_retry_count,
            import_last_error: row.import_last_error.clone(),
            import_next_retry_at: row.import_next_retry_at.map(|t| t.0),
            import_failed_at: row.import_failed_at.map(|t| t.0),
            imported_at: row.imported_at.map(|t| t.0),
            media_item_id: uuid_str(row.media_item_id.as_ref()),
            episode_id: uuid_str(row.episode_id.as_ref()),
            library_path_id: uuid_str(row.library_path_id.as_ref()),
        }
    }
}
