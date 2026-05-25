use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "UserProfile")]
pub struct UserProfile {
    pub id: ID,
    pub username: Option<String>,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub role: String,
    pub avatar_url: Option<String>,
    pub last_login_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

impl UserProfile {
    pub fn from_row(row: &mydia_rs_entities::users::Model) -> Self {
        Self {
            id: ID(row.id.0.to_string()),
            username: row.username.clone(),
            email: row.email.clone(),
            display_name: row.display_name.clone(),
            role: row.role.clone(),
            avatar_url: row.avatar_url.clone(),
            last_login_at: row.last_login_at.map(|t| t.0),
            inserted_at: row.inserted_at.0,
        }
    }
}
