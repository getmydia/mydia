use async_graphql::{Context, Enum, Object};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Condition, Expr};
use sea_orm::{ExprTrait, QueryOrder, QuerySelect};

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::DownloadRecord;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Enum)]
#[graphql(name = "DownloadFilter")]
pub enum DownloadFilter {
    #[graphql(name = "queue")]
    Queue,
    #[graphql(name = "completed")]
    Completed,
    #[graphql(name = "issues")]
    Issues,
}

#[derive(Default)]
pub struct DownloadQueries;

#[Object]
impl DownloadQueries {
    async fn downloads(
        &self,
        ctx: &Context<'_>,
        filter: DownloadFilter,
    ) -> async_graphql::Result<Vec<DownloadRecord>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        use mydia_rs_entities::downloads::Column;

        let completed_null = Expr::col(Column::CompletedAt).is_null();
        let completed_not_null = Expr::col(Column::CompletedAt).is_not_null();
        let error_null = Expr::col(Column::ErrorMessage).is_null();
        let error_empty = Expr::col(Column::ErrorMessage).eq("");
        let import_error_null = Expr::col(Column::ImportLastError).is_null();
        let import_error_empty = Expr::col(Column::ImportLastError).eq("");
        let import_failed_null = Expr::col(Column::ImportFailedAt).is_null();
        let error_not_null = Expr::col(Column::ErrorMessage).is_not_null();
        let error_neq_empty = Expr::col(Column::ErrorMessage).ne("");
        let import_error_not_null = Expr::col(Column::ImportLastError).is_not_null();
        let import_error_neq_empty = Expr::col(Column::ImportLastError).ne("");
        let import_failed_not_null = Expr::col(Column::ImportFailedAt).is_not_null();

        let condition = match filter {
            DownloadFilter::Queue => Condition::all()
                .add(completed_null)
                .add(error_null.or(error_empty))
                .add(import_error_null.or(import_error_empty))
                .add(import_failed_null),
            DownloadFilter::Completed => Condition::all().add(completed_not_null),
            DownloadFilter::Issues => Condition::all().add(completed_null).add(
                Condition::any()
                    .add(error_not_null.and(error_neq_empty))
                    .add(import_error_not_null.and(import_error_neq_empty))
                    .add(import_failed_not_null),
            ),
        };

        let rows = mydia_rs_entities::downloads::Entity::find()
            .filter(condition)
            .order_by_desc(Column::InsertedAt)
            .limit(500)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(DownloadRecord::from_row).collect())
    }
}
