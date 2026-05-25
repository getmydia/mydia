use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DownloadClient")]
pub struct DownloadClient {
    pub id: async_graphql::ID,
    pub name: String,
    #[graphql(name = "type")]
    pub type_: String,
    pub enabled: bool,
    pub priority: Option<i32>,
    pub host: Option<String>,
    pub port: Option<i32>,
    pub use_ssl: Option<bool>,
    pub url_base: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub api_key: Option<String>,
    pub category: Option<String>,
    pub download_directory: Option<String>,
    pub connection_settings: Option<String>,
    pub remove_completed: bool,
    pub incomplete_grace_minutes: Option<i32>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl DownloadClient {
    pub fn from_row(row: &mydia_rs_entities::download_client_configs::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            name: row.name.clone(),
            type_: row.r#type.clone(),
            enabled: row.enabled.unwrap_or(false),
            priority: row.priority,
            host: row.host.clone(),
            port: row.port,
            use_ssl: row.use_ssl,
            url_base: row.url_base.clone(),
            username: row.username.clone(),
            password: row.password.clone(),
            api_key: row.api_key.clone(),
            category: row.category.clone(),
            download_directory: row.download_directory.clone(),
            connection_settings: row.connection_settings.clone(),
            remove_completed: row.remove_completed.unwrap_or(false),
            incomplete_grace_minutes: row.incomplete_grace_minutes,
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        })
    }
}
