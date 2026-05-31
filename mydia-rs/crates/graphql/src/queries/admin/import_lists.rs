use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Condition, Expr};
use sea_orm::ExprTrait;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{ImportList, ImportListItem};

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct ImportListQueries;

#[Object]
impl ImportListQueries {
    async fn import_lists(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<ImportList>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::import_lists::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(ImportList::from_row).collect())
    }

    async fn import_list(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<ImportList>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row = mydia_rs_entities::import_lists::Entity::find_by_id(parse_id(id.as_str())?)
            .one(&state.db)
            .await?;
        Ok(row.as_ref().and_then(ImportList::from_row))
    }

    async fn import_list_items(
        &self,
        ctx: &Context<'_>,
        import_list_id: ID,
    ) -> async_graphql::Result<Vec<ImportListItem>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let id = parse_id(import_list_id.as_str())?;
        let rows = mydia_rs_entities::import_list_items::Entity::find()
            .filter(
                Condition::all().add(
                    Expr::col(mydia_rs_entities::import_list_items::Column::ImportListId)
                        .eq(id.into_simple_expr(backend)),
                ),
            )
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(ImportListItem::from_row).collect())
    }
}
