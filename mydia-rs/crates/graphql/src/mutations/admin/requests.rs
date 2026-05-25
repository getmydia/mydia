use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct AdminRequestMutations;

#[Object]
impl AdminRequestMutations {
    async fn approve_request(
        &self,
        ctx: &Context<'_>,
        id: ID,
        notes: Option<String>,
    ) -> async_graphql::Result<bool> {
        let admin = require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;
        let now = DateTimeSecs::from(chrono::Utc::now());
        let admin_id = uuid::Uuid::parse_str(&admin.id.to_string())
            .map(UuidText)
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let active = mydia_rs_entities::media_requests::ActiveModel {
            id: sea_orm::Unchanged(uid),
            status: Set("approved".to_string()),
            admin_notes: Set(notes),
            approved_at: Set(Some(now)),
            approved_by_id: Set(Some(admin_id)),
            rejection_reason: Set(None),
            rejected_at: Set(None),
            updated_at: Set(now),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(true)
    }

    async fn reject_request(
        &self,
        ctx: &Context<'_>,
        id: ID,
        notes: Option<String>,
    ) -> async_graphql::Result<bool> {
        let _admin = require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;
        let now = DateTimeSecs::from(chrono::Utc::now());

        let active = mydia_rs_entities::media_requests::ActiveModel {
            id: sea_orm::Unchanged(uid),
            status: Set("rejected".to_string()),
            admin_notes: Set(notes.clone()),
            rejection_reason: Set(notes),
            rejected_at: Set(Some(now)),
            updated_at: Set(now),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(true)
    }
}
