//! `:toggle_favorite_result` — port of
//! `lib/mydia_web/schema/common_types.ex:132-136`.

use async_graphql::{SimpleObject, ID};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ToggleFavoriteResult")]
pub struct ToggleFavoriteResult {
    pub is_favorite: bool,
    pub media_item_id: ID,
}
