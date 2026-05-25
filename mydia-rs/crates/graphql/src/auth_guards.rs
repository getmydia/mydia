use async_graphql::Context;

use crate::context::{CurrentUser, GraphqlRequestContext};

pub fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}

pub fn require_admin<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    let user = require_user(ctx)?;
    if !user.is_admin() {
        return Err(async_graphql::Error::new(
            "Admin role required for this operation",
        ));
    }
    Ok(user)
}
