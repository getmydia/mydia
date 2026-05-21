//! `apiKeys` query — port of
//! `lib/mydia_web/schema/resolvers/api_key_resolver.ex:8-18`.

use async_graphql::{Context, Object};

use crate::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use crate::repos::api_keys;
use crate::types::ApiKeyObject;

#[derive(Default)]
pub struct ApiKeyQueries;

#[Object]
impl ApiKeyQueries {
    async fn api_keys(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<ApiKeyObject>> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = api_keys::list_for_user(&state.db, &user.id.to_string()).await?;
        Ok(rows.iter().map(ApiKeyObject::from_row).collect())
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
