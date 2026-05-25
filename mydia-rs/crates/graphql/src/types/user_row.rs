//! User row type for the admin users list — matches the Dioxus `UserRow`
//! from `crates/web/src/server_fns/admin/users.rs`.

use async_graphql::{InputObject, SimpleObject, ID};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "UserRow")]
pub struct UserRow {
    pub id: ID,
    pub username: Option<String>,
    pub email: Option<String>,
    pub role: String,
    pub is_oidc: bool,
    pub last_login_at: Option<String>,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "CreateUserInput")]
pub struct CreateUserInput {
    pub username: String,
    pub email: String,
    pub password: String,
    pub role: Option<String>,
}

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "UpdateUserRoleInput")]
pub struct UpdateUserRoleInput {
    pub id: ID,
    pub role: String,
}

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "SetupAdminInput")]
pub struct SetupAdminInput {
    pub username: String,
    pub email: String,
    pub password: String,
}
