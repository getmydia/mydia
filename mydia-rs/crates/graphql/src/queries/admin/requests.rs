use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use sea_orm::QueryOrder;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::MediaRequest;

#[derive(Default)]
pub struct AdminRequestQueries;

#[Object]
impl AdminRequestQueries {
    async fn admin_requests(
        &self,
        ctx: &Context<'_>,
        status: Option<String>,
    ) -> async_graphql::Result<Vec<MediaRequest>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let mut q = mydia_rs_entities::media_requests::Entity::find();

        if let Some(s) = status {
            if !s.is_empty() {
                q = q.filter(mydia_rs_entities::media_requests::Column::Status.eq(s));
            }
        }

        let rows = q
            .order_by_desc(mydia_rs_entities::media_requests::Column::InsertedAt)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(MediaRequest::from_row).collect())
    }
}
