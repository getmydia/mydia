use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ImportList")]
pub struct ImportList {
    pub id: async_graphql::ID,
    pub name: String,
    #[graphql(name = "type")]
    pub type_: String,
    pub media_type: String,
    pub enabled: bool,
    pub sync_interval: i32,
    pub auto_add: bool,
    pub monitored: bool,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub sync_error: Option<String>,
    pub quality_profile_id: Option<String>,
    pub library_path_id: Option<String>,
    pub target_collection_id: Option<String>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl ImportList {
    pub fn from_row(row: &mydia_rs_entities::import_lists::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            name: row.name.clone(),
            type_: row.r#type.clone(),
            media_type: row.media_type.clone(),
            enabled: row.enabled,
            sync_interval: row.sync_interval,
            auto_add: row.auto_add,
            monitored: row.monitored,
            last_synced_at: row.last_synced_at.as_ref().map(|t| t.0),
            sync_error: row.sync_error.clone(),
            quality_profile_id: row.quality_profile_id.as_ref().map(|id| id.0.to_string()),
            library_path_id: row.library_path_id.as_ref().map(|id| id.0.to_string()),
            target_collection_id: row.target_collection_id.as_ref().map(|id| id.0.to_string()),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        })
    }
}
