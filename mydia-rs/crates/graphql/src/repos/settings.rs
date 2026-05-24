//! Port of the slice of `Mydia.Settings` the browse + admin resolvers
//! call into.
//!
//! Post-U13 cutover: SeaORM-native. The dialect-divergent `Db` enum is
//! gone; reads go through `library_paths::Entity::find()` against
//! `&DatabaseConnection`.

use mydia_rs_db::types::UuidText;
use mydia_rs_entities::library_paths;
use sea_orm::entity::prelude::*;
use sea_orm::query::QueryOrder;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::DatabaseConnection;
use uuid::Uuid;

/// List all library paths, ordered by `path`. Filters out the
/// `disabled = true` rows the admin marks as unused. Mirrors
/// `Mydia.Settings.list_library_paths/0`.
pub async fn list_library_paths(
    db: &DatabaseConnection,
) -> Result<Vec<library_paths::Model>, DbErr> {
    library_paths::Entity::find()
        .filter(library_paths::Column::Disabled.eq(false))
        .order_by_asc(library_paths::Column::Path)
        .all(db)
        .await
}

/// Fetch one library path by UUID.
pub async fn get_library_path(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<library_paths::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(id) else {
        return Ok(None);
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    library_paths::Entity::find()
        .filter(Expr::col(library_paths::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}
