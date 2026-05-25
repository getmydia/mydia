use async_graphql::{Context, Object};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::SettingRow;

#[derive(Default)]
pub struct SettingsMutations;

#[Object]
impl SettingsMutations {
    async fn update_setting(
        &self,
        ctx: &Context<'_>,
        key: String,
        value: String,
    ) -> async_graphql::Result<SettingRow> {
        let user = require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let now = DateTimeSecs::from(chrono::Utc::now());
        let user_uuid = UuidText::from(user.id);
        let backend = state.db.get_database_backend();

        let existing = mydia_rs_entities::config_settings::Entity::find()
            .filter(mydia_rs_entities::config_settings::Column::Key.eq(key.clone()))
            .one(&state.db)
            .await?;

        if let Some(row) = existing {
            mydia_rs_entities::config_settings::Entity::update_many()
                .col_expr(
                    mydia_rs_entities::config_settings::Column::Value,
                    Expr::value(Some(value.clone())),
                )
                .col_expr(
                    mydia_rs_entities::config_settings::Column::UpdatedById,
                    user_uuid.into_simple_expr(backend),
                )
                .col_expr(
                    mydia_rs_entities::config_settings::Column::UpdatedAt,
                    now.into_simple_expr(backend),
                )
                .filter(
                    Expr::col(mydia_rs_entities::config_settings::Column::Id)
                        .eq(row.id.into_simple_expr(backend)),
                )
                .exec(&state.db)
                .await?;
        } else {
            let id = UuidText::from(uuid::Uuid::new_v4());
            let am = mydia_rs_entities::config_settings::ActiveModel {
                id: Set(id),
                key: Set(key.clone()),
                value: Set(Some(value.clone())),
                category: Set("Custom".to_owned()),
                description: Set(None),
                updated_by_id: Set(Some(user_uuid)),
                inserted_at: Set(now),
                updated_at: Set(now),
            };
            mydia_rs_db::insert_active_model(am, &state.db).await?;
        }

        Ok(SettingRow {
            key,
            category: "Custom".to_owned(),
            label: String::new(),
            kind: "string".to_owned(),
            value,
            source: crate::types::ConfigSource::Database,
            description: None,
            placeholder: None,
        })
    }
}
