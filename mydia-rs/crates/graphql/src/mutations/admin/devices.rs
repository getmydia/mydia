use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::RevokeDeviceResult;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct AdminDeviceMutations;

#[Object]
impl AdminDeviceMutations {
    async fn revoke_device(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<RevokeDeviceResult> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;

        let now = mydia_rs_db::types::DateTimeSecs::from(chrono::Utc::now());
        let active = mydia_rs_entities::remote_devices::ActiveModel {
            id: sea_orm::Unchanged(uid),
            revoked_at: Set(Some(now)),
            ..Default::default()
        };
        let row = mydia_rs_db::update_active_model(active, &state.db).await?;

        let device = crate::types::RemoteDevice {
            id: ID(row.id.0.to_string()),
            device_name: row.device_name.clone(),
            platform: row.platform.clone(),
            last_seen_at: row.last_seen_at.map(|t| t.0),
            is_revoked: true,
            created_at: row.inserted_at.0,
        };

        Ok(RevokeDeviceResult {
            success: true,
            device: Some(device),
        })
    }
}
