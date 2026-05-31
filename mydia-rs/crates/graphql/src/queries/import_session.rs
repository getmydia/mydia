use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::sea_query::Condition;
use sea_orm::sea_query::Expr;
use sea_orm::{ColumnTrait, EntityTrait, ExprTrait, QueryFilter, QueryOrder};
use uuid::Uuid;

use crate::context::{GraphqlAppState, GraphqlRequestContext};
use crate::types::ImportSession;

#[derive(Default)]
pub struct ImportSessionQueries;

#[Object]
impl ImportSessionQueries {
    async fn active_import_session(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Option<ImportSession>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();

        let request_ctx = ctx.data_opt::<GraphqlRequestContext>();
        let Some(current_user) = request_ctx.and_then(|r| r.current_user.as_ref()) else {
            return Ok(None);
        };
        let user_id = UuidText(current_user.id);

        let now = DateTimeSecs::from(chrono::Utc::now());
        let row = mydia_rs_entities::import_sessions::Entity::find()
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(user_id.into_simple_expr(backend)),
                    )
                    .add(mydia_rs_entities::import_sessions::Column::Status.eq("active"))
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::ExpiresAt)
                            .gt(now.into_simple_expr(backend)),
                    ),
            )
            .order_by_desc(mydia_rs_entities::import_sessions::Column::InsertedAt)
            .one(&state.db)
            .await?;
        Ok(row.as_ref().and_then(ImportSession::from_row))
    }

    async fn import_session(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<ImportSession>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();

        let Ok(uuid) = Uuid::parse_str(id.as_str()) else {
            return Ok(None);
        };

        let request_ctx = ctx.data_opt::<GraphqlRequestContext>();
        let current_user_id = request_ctx
            .and_then(|r| r.current_user.as_ref())
            .map(|u| u.id);

        let row = mydia_rs_entities::import_sessions::Entity::find()
            .filter(
                Condition::all().add(
                    Expr::col(mydia_rs_entities::import_sessions::Column::Id)
                        .eq(UuidText(uuid).into_simple_expr(backend)),
                ),
            )
            .one(&state.db)
            .await?;

        Ok(row
            .filter(|r| current_user_id == Some(r.user_id.0))
            .as_ref()
            .and_then(ImportSession::from_row))
    }
}
