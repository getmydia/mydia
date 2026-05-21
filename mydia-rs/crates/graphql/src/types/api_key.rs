//! `:api_key` and `:create_api_key_result` types — port of
//! `common_types.ex:147-165`.

use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ApiKey")]
pub struct ApiKeyObject {
    pub id: ID,
    pub name: String,
    pub key_prefix: String,
    pub permissions: Vec<String>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

impl ApiKeyObject {
    pub fn from_row(row: &mydia_rs_models::ApiKey) -> Self {
        Self {
            id: ID(row.id.0.to_string()),
            name: row.name.clone().unwrap_or_default(),
            key_prefix: row.key_prefix.clone().unwrap_or_default(),
            permissions: row
                .permissions
                .as_ref()
                .map(|p| p.0.clone())
                .unwrap_or_default(),
            last_used_at: row.last_used_at.map(|d| d.0),
            expires_at: row.expires_at.map(|d| d.0),
            revoked_at: row.revoked_at.map(|d| d.0),
            inserted_at: row.inserted_at.0,
        }
    }
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "CreateApiKeyResult")]
pub struct CreateApiKeyResult {
    pub api_key: ApiKeyObject,
    pub key: String,
}
