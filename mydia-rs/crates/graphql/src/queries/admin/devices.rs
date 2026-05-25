use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::RemoteDevice;

#[derive(Default)]
pub struct AdminDeviceQueries;

#[Object]
impl AdminDeviceQueries {
    async fn devices_by_user(
        &self,
        ctx: &Context<'_>,
        user_id: ID,
    ) -> async_graphql::Result<Vec<RemoteDevice>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = uuid::Uuid::parse_str(user_id.as_str())
            .map(UuidText)
            .map_err(|_| async_graphql::Error::new("Invalid user id format"))?;

        let backend = state.db.get_database_backend();

        let rows = mydia_rs_entities::remote_devices::Entity::find()
            .filter(
                Expr::col(mydia_rs_entities::remote_devices::Column::UserId)
                    .eq(uid.into_simple_expr(backend)),
            )
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(remote_device_from_row).collect())
    }
}

fn remote_device_from_row(row: &mydia_rs_entities::remote_devices::Model) -> RemoteDevice {
    RemoteDevice {
        id: ID(row.id.0.to_string()),
        device_name: row.device_name.clone(),
        platform: row.platform.clone(),
        last_seen_at: row.last_seen_at.map(|t| t.0),
        is_revoked: row.revoked_at.is_some(),
        created_at: row.inserted_at.0,
    }
}
