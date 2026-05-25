use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MediaServer")]
pub struct MediaServer {
    pub id: async_graphql::ID,
    pub name: String,
    #[graphql(name = "type")]
    pub type_: String,
    pub enabled: bool,
    pub url: String,
    pub token: Option<String>,
    pub connection_settings: Option<String>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl MediaServer {
    pub fn from_row(row: &mydia_rs_entities::media_server_configs::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            name: row.name.clone(),
            type_: row.r#type.clone(),
            enabled: row.enabled.unwrap_or(false),
            url: row.url.clone(),
            token: row.token.clone(),
            connection_settings: row.connection_settings.clone(),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        })
    }
}
