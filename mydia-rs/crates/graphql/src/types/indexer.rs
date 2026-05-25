use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Indexer")]
pub struct Indexer {
    pub id: async_graphql::ID,
    pub name: String,
    #[graphql(name = "type")]
    pub type_: String,
    pub enabled: bool,
    pub priority: Option<i32>,
    pub base_url: Option<String>,
    pub api_key: Option<String>,
    pub rate_limit: Option<i32>,
    pub connection_settings: Option<String>,
    pub env_name: Option<String>,
    pub indexer_ids: Option<Vec<String>>,
    pub categories: Option<Vec<String>>,
    pub min_post_age_minutes: Option<i32>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Indexer {
    pub fn from_row(row: &mydia_rs_entities::indexer_configs::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            name: row.name.clone(),
            type_: row.r#type.clone(),
            enabled: row.enabled.unwrap_or(false),
            priority: row.priority,
            base_url: row.base_url.clone(),
            api_key: row.api_key.clone(),
            rate_limit: row.rate_limit,
            connection_settings: row.connection_settings.clone(),
            env_name: row.env_name.clone(),
            indexer_ids: row.indexer_ids.as_ref().map(|a| a.0.clone()),
            categories: row.categories.as_ref().map(|a| a.0.clone()),
            min_post_age_minutes: row.min_post_age_minutes,
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        })
    }
}
