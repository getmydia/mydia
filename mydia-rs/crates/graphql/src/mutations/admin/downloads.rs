use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use mydia_rs_pubsub::Event;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct AdminDownloadMutations;

#[Object]
impl AdminDownloadMutations {
    async fn cancel_download(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;

        let now = mydia_rs_db::types::DateTimeSecs::from(chrono::Utc::now());
        let active = mydia_rs_entities::downloads::ActiveModel {
            id: sea_orm::Unchanged(uid),
            completed_at: Set(Some(now)),
            error_message: Set(Some("Cancelled by admin".to_string())),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(active, &state.db).await?;

        state.pubsub.publish(
            "downloads",
            Event::from_json(serde_json::json!({"id": id.as_str(), "status": "cancelled"})),
        );
        Ok(true)
    }

    async fn manually_match_download(
        &self,
        ctx: &Context<'_>,
        id: ID,
        media_id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;
        let mid = uuid::Uuid::parse_str(media_id.as_str())
            .map(UuidText)
            .map_err(|_| async_graphql::Error::new("Invalid media id format"))?;

        let active = mydia_rs_entities::downloads::ActiveModel {
            id: sea_orm::Unchanged(uid),
            media_item_id: Set(Some(mid)),
            match_status: Set(Some("manual".to_string())),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(true)
    }
}
