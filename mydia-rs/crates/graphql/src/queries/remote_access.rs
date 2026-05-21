//! Remote access query — stub for U14 until U29 wires the real
//! `Mydia.RemoteAccess.p2p_status/0` analog.
//!
//! Phoenix returns `{enabled: false, endpoint_addr: nil,
//! connected_peers: 0}` whenever the P2P server isn't running; that
//! is also the U14 default until U29 lights up the P2P seam.

use async_graphql::{Context, Object};

use crate::context::{CurrentUser, GraphqlRequestContext};
use crate::types::RemoteAccessStatus;

#[derive(Default)]
pub struct RemoteAccessQueries;

#[Object]
impl RemoteAccessQueries {
    async fn remote_access_status(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<RemoteAccessStatus> {
        let _user = require_user(ctx)?;
        Ok(RemoteAccessStatus {
            enabled: false,
            endpoint_addr: None,
            connected_peers: 0,
        })
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}
