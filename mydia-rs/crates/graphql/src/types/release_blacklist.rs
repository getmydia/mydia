use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ReleaseBlacklistEntry")]
pub struct ReleaseBlacklistEntry {
    pub id: async_graphql::ID,
    pub indexer: String,
    pub guid: String,
    pub title: String,
    pub failure_reason: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

impl ReleaseBlacklistEntry {
    pub fn from_row(row: &mydia_rs_entities::release_blacklist::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            indexer: row.indexer.clone(),
            guid: row.guid.clone(),
            title: row.title.clone(),
            failure_reason: row.failure_reason.clone(),
            expires_at: row.expires_at.as_ref().map(|t| t.0),
            inserted_at: row.inserted_at.0,
        })
    }
}
