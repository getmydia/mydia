use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::QualityProfile;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct QualityProfileQueries;

#[Object]
impl QualityProfileQueries {
    async fn quality_profiles(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Vec<QualityProfile>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::quality_profiles::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(QualityProfile::from_row).collect())
    }

    async fn quality_profile(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<QualityProfile>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row = mydia_rs_entities::quality_profiles::Entity::find_by_id(parse_id(id.as_str())?)
            .one(&state.db)
            .await?;
        Ok(row.as_ref().and_then(QualityProfile::from_row))
    }
}
