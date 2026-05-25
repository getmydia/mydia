use async_graphql::{Context, Object};
use mydia_rs_pubsub::Event;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;

#[derive(Default)]
pub struct JobMutations;

#[Object]
impl JobMutations {
    async fn trigger_job(&self, ctx: &Context<'_>, name: String) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        state.pubsub.publish(
            "jobs:control",
            Event::from_json(serde_json::json!({"name": name})),
        );
        Ok(true)
    }
}
