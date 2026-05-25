use async_graphql::{Context, Object};

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::repos::accounts;
use crate::types::UserProfile;

#[derive(Default)]
pub struct ProfileQueries;

#[Object]
impl ProfileQueries {
    async fn current_profile(&self, ctx: &Context<'_>) -> async_graphql::Result<UserProfile> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row = accounts::get_user_by_id(&state.db, &user.id.to_string())
            .await?
            .ok_or_else(|| async_graphql::Error::new("User not found"))?;
        Ok(UserProfile::from_row(&row))
    }
}
