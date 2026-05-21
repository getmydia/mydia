//! `:user` GraphQL object — port of `common_types.ex:186-192`.

use async_graphql::{SimpleObject, ID};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "User")]
pub struct UserObject {
    pub id: ID,
    pub username: Option<String>,
    pub email: Option<String>,
    pub display_name: Option<String>,
}
