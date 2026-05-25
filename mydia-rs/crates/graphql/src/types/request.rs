use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};
use mydia_rs_db::types::UuidText;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MediaRequest")]
pub struct MediaRequest {
    pub id: ID,
    pub media_type: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i32>,
    pub imdb_id: Option<String>,
    pub status: String,
    pub requester_notes: Option<String>,
    pub admin_notes: Option<String>,
    pub rejection_reason: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
    pub rejected_at: Option<DateTime<Utc>>,
    pub requester_id: String,
    pub approved_by_id: Option<String>,
    pub media_item_id: Option<String>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl MediaRequest {
    pub fn from_row(row: &mydia_rs_entities::media_requests::Model) -> Self {
        fn uuid_str(id: Option<&UuidText>) -> Option<String> {
            id.map(|u| u.0.to_string())
        }

        Self {
            id: ID(row.id.0.to_string()),
            media_type: row.media_type.clone(),
            title: row.title.clone(),
            original_title: row.original_title.clone(),
            year: row.year,
            tmdb_id: row.tmdb_id,
            imdb_id: row.imdb_id.clone(),
            status: row.status.clone(),
            requester_notes: row.requester_notes.clone(),
            admin_notes: row.admin_notes.clone(),
            rejection_reason: row.rejection_reason.clone(),
            approved_at: row.approved_at.map(|t| t.0),
            rejected_at: row.rejected_at.map(|t| t.0),
            requester_id: row.requester_id.0.to_string(),
            approved_by_id: uuid_str(row.approved_by_id.as_ref()),
            media_item_id: uuid_str(row.media_item_id.as_ref()),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        }
    }
}
