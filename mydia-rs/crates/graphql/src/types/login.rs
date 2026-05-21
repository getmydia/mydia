//! Login input + result types — port of `common_types.ex:168-183`.

use async_graphql::{InputObject, SimpleObject};

use crate::types::user::UserObject;

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "LoginInput")]
pub struct LoginInput {
    pub username: String,
    pub password: String,
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "LoginResult")]
pub struct LoginResult {
    pub token: String,
    pub user: UserObject,
    pub expires_in: i32,
}
