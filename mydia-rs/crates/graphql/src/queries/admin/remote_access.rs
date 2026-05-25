use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{RemoteAccessStatus, RemoteDevice};

#[derive(Default)]
pub struct AdminRemoteAccessQueries;

#[Object]
impl AdminRemoteAccessQueries {
    async fn paired_devices(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<RemoteDevice>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let rows = mydia_rs_entities::remote_devices::Entity::find()
            .all(&state.db)
            .await?;

        Ok(rows
            .iter()
            .map(|row| RemoteDevice {
                id: async_graphql::ID(row.id.0.to_string()),
                device_name: row.device_name.clone(),
                platform: row.platform.clone(),
                last_seen_at: row.last_seen_at.map(|t| t.0),
                is_revoked: row.revoked_at.is_some(),
                created_at: row.inserted_at.0,
            })
            .collect())
    }

    async fn remote_access_status(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<RemoteAccessStatus> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let config = mydia_rs_entities::remote_access_config::Entity::find()
            .one(&state.db)
            .await?;

        let enabled = config.as_ref().is_some_and(|c| c.enabled);

        let connected_peers = mydia_rs_entities::remote_devices::Entity::find()
            .filter(mydia_rs_entities::remote_devices::Column::RevokedAt.is_null())
            .count(&state.db)
            .await? as i32;

        Ok(RemoteAccessStatus {
            enabled,
            endpoint_addr: None,
            connected_peers,
        })
    }
}
