use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::QualityProfile;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct QualityProfileInput {
    pub name: String,
    pub upgrades_allowed: Option<bool>,
    pub upgrade_until_quality: Option<String>,
    pub qualities: String,
    pub description: Option<String>,
    pub quality_standards: Option<String>,
    pub metadata_preferences: Option<String>,
    pub customizations: Option<String>,
}

#[derive(Default)]
pub struct QualityProfileMutations;

#[Object]
impl QualityProfileMutations {
    async fn create_quality_profile(
        &self,
        ctx: &Context<'_>,
        input: QualityProfileInput,
    ) -> async_graphql::Result<QualityProfile> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::quality_profiles::ActiveModel {
            id: Set(UuidText(id)),
            name: Set(input.name),
            upgrades_allowed: Set(input.upgrades_allowed),
            upgrade_until_quality: Set(input.upgrade_until_quality),
            qualities: Set(input.qualities),
            description: Set(input.description),
            quality_standards: Set(input.quality_standards),
            metadata_preferences: Set(input.metadata_preferences),
            customizations: Set(input.customizations),
            is_system: Set(Some(false)),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        QualityProfile::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create quality profile"))
    }

    async fn update_quality_profile(
        &self,
        ctx: &Context<'_>,
        id: ID,
        input: QualityProfileInput,
    ) -> async_graphql::Result<Option<QualityProfile>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let active = mydia_rs_entities::quality_profiles::ActiveModel {
            id: sea_orm::Unchanged(parse_id(id.as_str())?),
            name: Set(input.name),
            upgrades_allowed: Set(input.upgrades_allowed),
            upgrade_until_quality: Set(input.upgrade_until_quality),
            qualities: Set(input.qualities),
            description: Set(input.description),
            quality_standards: Set(input.quality_standards),
            metadata_preferences: Set(input.metadata_preferences),
            customizations: Set(input.customizations),
            ..Default::default()
        };

        let row = mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(QualityProfile::from_row(&row))
    }

    async fn delete_quality_profile(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::quality_profiles::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }
}
