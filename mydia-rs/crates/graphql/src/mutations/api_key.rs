//! API key mutations — port of
//! `lib/mydia_web/schema/resolvers/api_key_resolver.ex`.

use async_graphql::{Context, Object, ID};
use chrono::{DateTime, Utc};

use crate::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use crate::repos::api_keys;
use crate::types::{ApiKeyObject, CreateApiKeyResult};

#[derive(Default)]
pub struct ApiKeyMutations;

#[Object]
impl ApiKeyMutations {
    async fn create_api_key(
        &self,
        ctx: &Context<'_>,
        name: String,
        permissions: Option<Vec<String>>,
        expires_at: Option<DateTime<Utc>>,
    ) -> async_graphql::Result<CreateApiKeyResult> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let perms = permissions.unwrap_or_else(|| vec!["read".into(), "write".into()]);
        let issued =
            api_keys::create(&state.db, &user.id.to_string(), &name, perms, expires_at).await?;
        Ok(CreateApiKeyResult {
            api_key: ApiKeyObject::from_row(&issued.row),
            key: issued.plain_key,
        })
    }

    async fn revoke_api_key(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<ApiKeyObject> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let existing = api_keys::get_by_id(&state.db, id.as_str())
            .await?
            .ok_or_else(|| async_graphql::Error::new("API key not found"))?;
        if existing.user_id.0 != user.id {
            return Err(async_graphql::Error::new("Forbidden"));
        }
        let updated = api_keys::revoke(&state.db, id.as_str())
            .await?
            .ok_or_else(|| async_graphql::Error::new("API key not found"))?;
        Ok(ApiKeyObject::from_row(&updated))
    }

    async fn delete_api_key(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let existing = api_keys::get_by_id(&state.db, id.as_str())
            .await?
            .ok_or_else(|| async_graphql::Error::new("API key not found"))?;
        if existing.user_id.0 != user.id {
            return Err(async_graphql::Error::new("Forbidden"));
        }
        let deleted = api_keys::delete(&state.db, id.as_str()).await?;
        Ok(deleted)
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
