use async_graphql::{Context, Object};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::QueryOrder;
use uuid::Uuid;

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::types::MediaRequest;

#[derive(Default)]
pub struct RequestQueries;

#[Object]
impl RequestQueries {
    async fn my_requests(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<MediaRequest>> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let requester_id = Uuid::parse_str(&user.id.to_string())
            .map(UuidText)
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let rows = mydia_rs_entities::media_requests::Entity::find()
            .filter(
                Expr::col(mydia_rs_entities::media_requests::Column::RequesterId)
                    .eq(requester_id.into_simple_expr(backend)),
            )
            .order_by_desc(mydia_rs_entities::media_requests::Column::InsertedAt)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(MediaRequest::from_row).collect())
    }
}
