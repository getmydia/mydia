use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ImportListItem")]
pub struct ImportListItem {
    pub id: async_graphql::ID,
    pub import_list_id: async_graphql::ID,
    pub tmdb_id: i32,
    pub title: String,
    pub year: Option<i32>,
    pub poster_path: Option<String>,
    #[graphql(name = "posterUrl")]
    pub poster_url: Option<String>,
    pub status: String,
    pub skip_reason: Option<String>,
    pub discovered_at: DateTime<Utc>,
    pub media_item_id: Option<String>,
}

impl ImportListItem {
    pub fn from_row(row: &mydia_rs_entities::import_list_items::Model) -> Option<Self> {
        let poster_url = row
            .poster_path
            .as_deref()
            .and_then(|p| crate::metadata::poster_url(Some(p)));

        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            import_list_id: async_graphql::ID(row.import_list_id.0.to_string()),
            tmdb_id: row.tmdb_id,
            title: row.title.clone(),
            year: row.year,
            poster_path: row.poster_path.clone(),
            poster_url,
            status: row.status.clone(),
            skip_reason: row.skip_reason.clone(),
            discovered_at: row.discovered_at.0,
            media_item_id: row.media_item_id.as_ref().map(|id| id.0.to_string()),
        })
    }
}
