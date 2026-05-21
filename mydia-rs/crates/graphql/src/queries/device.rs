//! `devices` query — stub until U29 ports the `RemoteAccess` context
//! (paired remote devices live in the `remote_devices` table; the
//! model lands alongside U29). For U14 the resolver returns an empty
//! list for authenticated users, matching Phoenix's contract shape.

use async_graphql::{Context, Object};

use crate::context::{CurrentUser, GraphqlRequestContext};
use crate::types::RemoteDevice;

#[derive(Default)]
pub struct DeviceQueries;

#[Object]
impl DeviceQueries {
    async fn devices(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<RemoteDevice>> {
        let _user = require_user(ctx)?;
        // U29 implements the real list. Empty list here keeps the
        // schema contract intact for the parity replay harness.
        Ok(Vec::new())
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
