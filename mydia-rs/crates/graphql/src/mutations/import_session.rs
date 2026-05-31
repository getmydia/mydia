use async_graphql::{Context, Object, ID};
use chrono::{Duration, Utc};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::sea_query::{Condition, Expr};
use sea_orm::{ColumnTrait, EntityTrait, ExprTrait, QueryFilter, Set};
use uuid::Uuid;

use crate::context::{GraphqlAppState, GraphqlRequestContext};
use crate::types::ImportSession;

fn current_user_id(ctx: &Context<'_>) -> async_graphql::Result<Uuid> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .map(|u| u.id)
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}

#[derive(Default)]
pub struct ImportSessionMutations;

#[Object]
impl ImportSessionMutations {
    async fn create_import_session(
        &self,
        ctx: &Context<'_>,
        scan_path: String,
    ) -> async_graphql::Result<ImportSession> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_id = current_user_id(ctx)?;
        let now = DateTimeSecs::from(Utc::now());

        // Abandon any existing active sessions.
        let _ = mydia_rs_entities::import_sessions::Entity::update_many()
            .col_expr(
                mydia_rs_entities::import_sessions::Column::Status,
                Expr::value("abandoned"),
            )
            .col_expr(
                mydia_rs_entities::import_sessions::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(UuidText(user_id).into_simple_expr(backend)),
                    )
                    .add(mydia_rs_entities::import_sessions::Column::Status.eq("active")),
            )
            .exec(&state.db)
            .await?;

        let expires = DateTimeSecs::from(Utc::now() + Duration::hours(24));
        let id = UuidText(Uuid::new_v4());

        let am = mydia_rs_entities::import_sessions::ActiveModel {
            id: Set(id),
            user_id: Set(UuidText(user_id)),
            step: Set("select_path".into()),
            status: Set("active".into()),
            scan_path: Set(Some(scan_path)),
            expires_at: Set(Some(expires)),
            inserted_at: Set(now),
            updated_at: Set(now),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(am, &state.db).await?;
        ImportSession::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create import session"))
    }

    async fn update_import_session(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "id")] session_id: ID,
        step: String,
        session_data: Option<String>,
        scan_stats: Option<String>,
    ) -> async_graphql::Result<ImportSession> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_id = current_user_id(ctx)?;
        let now = DateTimeSecs::from(Utc::now());

        let Ok(uuid) = Uuid::parse_str(session_id.as_str()) else {
            return Err(async_graphql::Error::new("Invalid session ID"));
        };

        let valid_steps = ["select_path", "review", "importing", "complete"];
        if !valid_steps.contains(&step.as_str()) {
            return Err(async_graphql::Error::new(format!(
                "Invalid step: {step}. Must be one of: {valid_steps:?}"
            )));
        }

        let session = mydia_rs_entities::import_sessions::Entity::find()
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::Id)
                            .eq(UuidText(uuid).into_simple_expr(backend)),
                    )
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(UuidText(user_id).into_simple_expr(backend)),
                    ),
            )
            .one(&state.db)
            .await?;

        let Some(session) = session else {
            return Err(async_graphql::Error::new("Session not found"));
        };

        let mut am = mydia_rs_entities::import_sessions::ActiveModel {
            id: sea_orm::Unchanged(session.id),
            step: Set(step),
            updated_at: Set(now),
            ..Default::default()
        };

        if let Some(data) = session_data {
            am.session_data = Set(Some(data));
        }
        if let Some(stats) = scan_stats {
            am.scan_stats = Set(Some(stats));
        }

        let row = mydia_rs_db::update_active_model(am, &state.db).await?;
        ImportSession::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to update import session"))
    }

    async fn complete_import_session(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "id")] session_id: ID,
    ) -> async_graphql::Result<ImportSession> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_id = current_user_id(ctx)?;
        let now = DateTimeSecs::from(Utc::now());

        let Ok(uuid) = Uuid::parse_str(session_id.as_str()) else {
            return Err(async_graphql::Error::new("Invalid session ID"));
        };

        let session = mydia_rs_entities::import_sessions::Entity::find()
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::Id)
                            .eq(UuidText(uuid).into_simple_expr(backend)),
                    )
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(UuidText(user_id).into_simple_expr(backend)),
                    ),
            )
            .one(&state.db)
            .await?;

        let Some(session) = session else {
            return Err(async_graphql::Error::new("Session not found"));
        };

        let am = mydia_rs_entities::import_sessions::ActiveModel {
            id: sea_orm::Unchanged(session.id),
            status: Set("completed".into()),
            step: Set("complete".into()),
            completed_at: Set(Some(now)),
            updated_at: Set(now),
            ..Default::default()
        };

        let row = mydia_rs_db::update_active_model(am, &state.db).await?;
        ImportSession::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to complete import session"))
    }

    async fn abandon_import_session(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "id")] session_id: ID,
    ) -> async_graphql::Result<bool> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_id = current_user_id(ctx)?;
        let now = DateTimeSecs::from(Utc::now());

        let Ok(uuid) = Uuid::parse_str(session_id.as_str()) else {
            return Ok(false);
        };

        let res = mydia_rs_entities::import_sessions::Entity::update_many()
            .col_expr(
                mydia_rs_entities::import_sessions::Column::Status,
                Expr::value("abandoned"),
            )
            .col_expr(
                mydia_rs_entities::import_sessions::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::Id)
                            .eq(UuidText(uuid).into_simple_expr(backend)),
                    )
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(UuidText(user_id).into_simple_expr(backend)),
                    ),
            )
            .exec(&state.db)
            .await?;

        Ok(res.rows_affected > 0)
    }

    async fn abandon_all_import_sessions(&self, ctx: &Context<'_>) -> async_graphql::Result<i32> {
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_id = current_user_id(ctx)?;
        let now = DateTimeSecs::from(Utc::now());

        let res = mydia_rs_entities::import_sessions::Entity::update_many()
            .col_expr(
                mydia_rs_entities::import_sessions::Column::Status,
                Expr::value("abandoned"),
            )
            .col_expr(
                mydia_rs_entities::import_sessions::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Condition::all()
                    .add(
                        Expr::col(mydia_rs_entities::import_sessions::Column::UserId)
                            .eq(UuidText(user_id).into_simple_expr(backend)),
                    )
                    .add(mydia_rs_entities::import_sessions::Column::Status.eq("active")),
            )
            .exec(&state.db)
            .await?;

        Ok(res.rows_affected as i32)
    }
}
