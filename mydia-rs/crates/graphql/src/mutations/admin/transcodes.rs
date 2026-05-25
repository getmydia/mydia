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
pub struct TranscodeMutations;

#[Object]
impl TranscodeMutations {
    async fn cancel_transcode(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;

        let active = mydia_rs_entities::transcode_jobs::ActiveModel {
            id: sea_orm::Unchanged(uid),
            status: Set("cancelled".to_string()),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(active, &state.db).await?;

        state.pubsub.publish(
            "transcodes",
            Event::from_json(serde_json::json!({"id": id.as_str(), "status": "cancelled"})),
        );
        Ok(true)
    }
}
