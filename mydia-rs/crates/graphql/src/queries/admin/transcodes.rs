use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use sea_orm::QueryOrder;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::TranscodeJob;

#[derive(Default)]
pub struct TranscodeQueries;

#[Object]
impl TranscodeQueries {
    async fn transcodes(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<TranscodeJob>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let rows = mydia_rs_entities::transcode_jobs::Entity::find()
            .order_by_desc(mydia_rs_entities::transcode_jobs::Column::InsertedAt)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(TranscodeJob::from_row).collect())
    }
}
