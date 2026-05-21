//! `:collection` — port of `query_types.ex:231-240`.

use async_graphql::{SimpleObject, ID};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Collection")]
pub struct CollectionObject {
    pub id: ID,
    pub name: String,
    pub description: Option<String>,
    #[graphql(name = "type")]
    pub type_: String,
    pub visibility: String,
    pub item_count: i32,
    pub poster_paths: Vec<String>,
}
