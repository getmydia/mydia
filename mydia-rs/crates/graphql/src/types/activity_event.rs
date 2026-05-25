use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};
use serde_json::Value;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ActivityEvent")]
pub struct ActivityEvent {
    pub id: ID,
    pub category: String,
    pub r#type: String,
    pub actor_type: Option<String>,
    pub actor_id: Option<String>,
    pub resource_type: Option<String>,
    pub resource_id: Option<String>,
    pub severity: String,
    pub metadata: Option<Value>,
    pub inserted_at: DateTime<Utc>,
}

impl ActivityEvent {
    pub fn from_row(row: &mydia_rs_entities::events::Model) -> Self {
        Self {
            id: ID(row.id.0.to_string()),
            category: row.category.clone(),
            r#type: row.r#type.clone(),
            actor_type: row.actor_type.clone(),
            actor_id: row.actor_id.clone(),
            resource_type: row.resource_type.clone(),
            resource_id: row.resource_id.as_ref().map(|u| u.0.to_string()),
            severity: row.severity.clone(),
            metadata: row
                .metadata
                .as_deref()
                .and_then(|s| serde_json::from_str(s).ok()),
            inserted_at: row.inserted_at.0,
        }
    }
}
