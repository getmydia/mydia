//! Remote access mutations — stub until U29 wires the P2P seam.
//!
//! Both mutations need the `Mydia.RemoteAccess` analog: the claim-code
//! generator needs the relay HTTP client, and the media-token refresh
//! needs the JWT signer + `remote_devices` table. Stubbed for U14 with
//! a clear error; the schema contract holds for the parity replay
//! harness.

use async_graphql::{Context, Object};

use crate::context::{CurrentUser, GraphqlRequestContext};
use crate::types::{ClaimCodeObject, MediaTokenObject};

#[derive(Default)]
pub struct RemoteAccessMutations;

#[Object]
impl RemoteAccessMutations {
    async fn generate_claim_code(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<ClaimCodeObject> {
        let _user = require_user(ctx)?;
        Err(async_graphql::Error::new(
            "Claim code generation not implemented yet (lands in U29)",
        ))
    }

    async fn refresh_media_token(
        &self,
        _ctx: &Context<'_>,
        token: String,
    ) -> async_graphql::Result<MediaTokenObject> {
        let _ = token;
        Err(async_graphql::Error::new(
            "Media token refresh not implemented yet (lands in U29)",
        ))
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
