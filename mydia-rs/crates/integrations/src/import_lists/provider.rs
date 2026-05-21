//! `ImportListProvider` trait + shared types.
//!
//! Port of `lib/mydia/import_lists/provider.ex`. Phoenix uses an
//! Elixir behaviour with a `@callback`; in Rust we use an `async_trait`
//! so adapter implementations can do real I/O without leaking Pinned
//! futures into the call site.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::error::IntegrationError;

/// One item the provider returns. Matches Phoenix's
/// `Mydia.ImportLists.Provider.item()` type.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportItem {
    pub tmdb_id: i64,
    pub title: String,
    pub year: Option<i32>,
    pub poster_path: Option<String>,
    /// `"movie"` or `"tv_show"` — Phoenix never normalizes to an enum
    /// at this layer so we mirror it.
    pub media_type: String,
}

/// In-memory shape of a `import_lists` row that the provider needs to
/// fetch its items. Worker code constructs this from a sqlx fetch
/// before invoking the provider so the provider stays decoupled from
/// the schema.
#[derive(Debug, Clone)]
pub struct ImportListSpec {
    /// `type` column: `tmdb_trending`, `custom_url`, etc.
    pub list_type: String,
    /// `media_type` column: `"movie"` or `"tv_show"`.
    pub media_type: String,
    /// `config` column (JSON object). Per-list config — typically
    /// `{"list_url": "..."}` for custom URLs and TMDB user lists.
    pub config: serde_json::Value,
}

/// Behaviour every import-list source implements.
///
/// Phoenix's `@callback fetch_items/1` becomes an `async fn` so the
/// implementation can `.await` HTTP calls without spawning a wrapper
/// task.
#[async_trait]
pub trait ImportListProvider: Send + Sync {
    /// `true` if this provider can fetch items for `list_type`.
    fn supports(&self, list_type: &str) -> bool;

    /// Fetch the configured items.
    async fn fetch_items(&self, spec: &ImportListSpec)
        -> Result<Vec<ImportItem>, IntegrationError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_item_round_trips_through_json() {
        let item = ImportItem {
            tmdb_id: 27205,
            title: "Inception".into(),
            year: Some(2010),
            poster_path: Some("/poster.jpg".into()),
            media_type: "movie".into(),
        };
        let json = serde_json::to_string(&item).unwrap();
        let back: ImportItem = serde_json::from_str(&json).unwrap();
        assert_eq!(item, back);
    }
}
