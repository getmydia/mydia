use async_graphql::{Context, InputObject, Object};
use sea_orm::entity::prelude::*;
use sea_orm::{QueryOrder, QuerySelect};

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::ActivityEvent;

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "ActivityFilter")]
pub struct ActivityFilter {
    pub category: Option<String>,
    pub severity: Option<String>,
    pub resource_type: Option<String>,
}

#[derive(Default)]
pub struct ActivityQueries;

#[Object]
impl ActivityQueries {
    async fn activity(
        &self,
        ctx: &Context<'_>,
        filter: Option<ActivityFilter>,
        #[graphql(default = 50)] limit: i32,
    ) -> async_graphql::Result<Vec<ActivityEvent>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let mut q = mydia_rs_entities::events::Entity::find();
        if let Some(f) = &filter {
            if let Some(cat) = &f.category {
                q = q.filter(mydia_rs_entities::events::Column::Category.eq(cat.clone()));
            }
            if let Some(sev) = &f.severity {
                q = q.filter(mydia_rs_entities::events::Column::Severity.eq(sev.clone()));
            }
            if let Some(rt) = &f.resource_type {
                q = q.filter(mydia_rs_entities::events::Column::ResourceType.eq(rt.clone()));
            }
        }

        let rows = q
            .order_by_desc(mydia_rs_entities::events::Column::InsertedAt)
            .limit(limit.clamp(1, 200) as u64)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(ActivityEvent::from_row).collect())
    }
}
