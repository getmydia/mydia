//! Device mutations — stub for U14. The real `revoke_device` lights
//! up alongside the `remote_devices` model in U29. Until then the
//! mutation returns a not-implemented error; the schema shape is
//! intact for parity replay.

use async_graphql::{Context, Object, ID};

use crate::context::{CurrentUser, GraphqlRequestContext};
use crate::types::RevokeDeviceResult;

#[derive(Default)]
pub struct DeviceMutations;

#[Object]
impl DeviceMutations {
    async fn revoke_device(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<RevokeDeviceResult> {
        let _user = require_user(ctx)?;
        let _ = id;
        Err(async_graphql::Error::new(
            "Device revoke not implemented yet (lands in U29)",
        ))
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
