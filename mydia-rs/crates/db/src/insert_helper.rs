//! Engine-aware INSERT / UPDATE helpers for `SeaORM` `ActiveModel`s.
//!
//! These free functions replace vanilla `am.insert(&db)` /
//! `am.update(&db)` for any table touching the cross-engine wrapper
//! types in [`crate::types`]. The 2026-05-24 wrapper spike empirically
//! proved that a single context-free `From<Wrapper> for Value` impl
//! cannot satisfy both Postgres native columns (`uuid`, `timestamptz`,
//! `jsonb`, `text[]`) and `SQLite`'s Ecto-compat TEXT — so engine
//! awareness has to live somewhere. For reads, the per-wrapper
//! `TryGetable` impls engine-branch via [`sea_orm::QueryResult`]. For
//! writes, this helper is that "somewhere".
//!
//! The helper iterates the `ActiveModel`'s columns, looks at each
//! column's declared `ColumnType` (via `Column::def()`), and applies the
//! engine-appropriate cast to `Value::String` binds destined for
//! Postgres native columns. `SQLite` always falls through to a plain
//! `Expr::val` bind. Non-wrapper columns pass through unchanged on both
//! engines.
//!
//! `Expr::cust_with_values` is only used inside this helper and the
//! per-wrapper `into_simple_expr(backend)` builders. Any other use
//! anywhere else in the workspace is forbidden by the post-merge
//! verification grep documented in
//! `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`.

use sea_orm::sea_query::{ColumnType, Expr, ExprTrait, Query, SimpleExpr, Value};
use sea_orm::{
    ActiveModelTrait, ActiveValue, ColumnTrait, ConnectionTrait, DbBackend, DbErr, EntityName,
    EntityTrait, FromQueryResult, Iterable, PrimaryKeyToColumn,
};

/// Insert an `ActiveModel` through the engine-aware write path.
///
/// Iterates the model's columns, threading every `Set` / `Unchanged`
/// value through [`simple_expr_for_column`] so wrapper-typed Postgres
/// columns get the cast they need. Builds a `sea_query::InsertStatement`
/// with a `RETURNING` clause matching the entity's full column set, then
/// parses the returned row back into the entity's `Model`.
///
/// Both `SQLite` (3.35+) and Postgres support `RETURNING`; mydia-rs's
/// `SQLite` minimum is well past that threshold, so this path is uniform
/// across engines.
///
/// Vanilla [`ActiveModelTrait::insert`] is forbidden for wrapper-touched
/// tables — the workspace `clippy.toml` denies it. Use this function
/// instead.
pub async fn insert_active_model<A, C>(
    am: A,
    db: &C,
) -> Result<<A::Entity as EntityTrait>::Model, DbErr>
where
    A: ActiveModelTrait,
    C: ConnectionTrait,
{
    let backend = db.get_database_backend();
    let mut stmt = Query::insert();
    stmt.into_table(<A::Entity as Default>::default().table_ref());

    let mut columns: Vec<<A::Entity as EntityTrait>::Column> = Vec::new();
    let mut values: Vec<SimpleExpr> = Vec::new();

    for col in <A::Entity as EntityTrait>::Column::iter() {
        match am.get(col) {
            ActiveValue::Set(value) | ActiveValue::Unchanged(value) => {
                columns.push(col);
                values.push(simple_expr_for_column::<A::Entity>(col, value, backend));
            }
            ActiveValue::NotSet => {}
        }
    }

    if columns.is_empty() {
        stmt.or_default_values();
    } else {
        stmt.columns(columns);
        stmt.values_panic(values);
    }

    // RETURNING the full model lets us parse a Model without a second
    // round-trip to fetch by PK. SeaORM emits dialect-correct
    // `RETURNING ...` for Postgres and SQLite alike.
    let returning = Query::returning().exprs(
        <A::Entity as EntityTrait>::Column::iter()
            .map(|c| c.select_as(c.into_returning_expr(backend))),
    );
    stmt.returning(returning);

    let row = db.query_one(&stmt).await?.ok_or(DbErr::RecordNotInserted)?;
    <A::Entity as EntityTrait>::Model::from_query_result(&row, "")
}

/// Update an `ActiveModel` through the engine-aware write path.
///
/// Builds the WHERE clause from the model's primary key columns (which
/// must all be `Set` or `Unchanged` — `NotSet` PK returns
/// [`DbErr::PrimaryKeyNotSet`]). Builds the SET clause from every
/// non-PK `Set` value. Both halves route through
/// [`simple_expr_for_column`] so wrapper-typed Postgres columns get the
/// cast they need on either side of the statement.
///
/// `Unchanged` non-PK values do not appear in the SET clause — this
/// matches `SeaORM`'s vanilla `ActiveModelTrait::update` behavior. Models
/// with no `Set` non-PK columns return [`DbErr::UpdateGetPrimaryKey`].
///
/// Returns the updated model parsed from the `RETURNING` clause.
pub async fn update_active_model<A, C>(
    am: A,
    db: &C,
) -> Result<<A::Entity as EntityTrait>::Model, DbErr>
where
    A: ActiveModelTrait,
    C: ConnectionTrait,
{
    let backend = db.get_database_backend();
    let mut stmt = Query::update();
    stmt.table(<A::Entity as Default>::default().table_ref());

    // WHERE: every PK column must be Set or Unchanged.
    let mut pk_count = 0;
    for key in <A::Entity as EntityTrait>::PrimaryKey::iter() {
        let col = key.into_column();
        match am.get(col) {
            ActiveValue::Set(value) | ActiveValue::Unchanged(value) => {
                stmt.and_where(
                    Expr::col(col).eq(simple_expr_for_column::<A::Entity>(col, value, backend)),
                );
                pk_count += 1;
            }
            ActiveValue::NotSet => {
                return Err(DbErr::PrimaryKeyNotSet {
                    ctx: "update_active_model",
                });
            }
        }
    }
    if pk_count == 0 {
        return Err(DbErr::PrimaryKeyNotSet {
            ctx: "update_active_model",
        });
    }

    // SET: every non-PK column that is Set goes in. Unchanged and NotSet
    // are skipped — matches vanilla SeaORM semantics.
    let mut updated_any = false;
    for col in <A::Entity as EntityTrait>::Column::iter() {
        if <A::Entity as EntityTrait>::PrimaryKey::from_column(col).is_some() {
            continue;
        }
        if let ActiveValue::Set(value) = am.get(col) {
            stmt.value(
                col,
                simple_expr_for_column::<A::Entity>(col, value, backend),
            );
            updated_any = true;
        }
    }
    if !updated_any {
        return Err(DbErr::UpdateGetPrimaryKey);
    }

    let returning = Query::returning().exprs(
        <A::Entity as EntityTrait>::Column::iter()
            .map(|c| c.select_as(c.into_returning_expr(backend))),
    );
    stmt.returning(returning);

    let row = db.query_one(&stmt).await?.ok_or(DbErr::RecordNotUpdated)?;
    <A::Entity as EntityTrait>::Model::from_query_result(&row, "")
}

/// Translate a column's `ActiveValue` payload into a `SimpleExpr` that
/// binds correctly on the active backend.
///
/// On `SQLite`, every value flows through `Expr::val(...)` unchanged — the
/// wrapper marshalling layer already produces the TEXT form Ecto reads.
/// On Postgres, `Value::String(Some(_))` payloads destined for a native
/// column type (`uuid`, `timestamptz`, `jsonb`, `text[]`) are wrapped in
/// the matching cast template. Non-wrapper Postgres columns (integers,
/// booleans, plain text, varbinary) pass through unchanged.
///
/// The cast templates mirror the per-wrapper `into_simple_expr(backend)`
/// builders in [`crate::types`]; both surfaces emit identical SQL for
/// wrapper-touched columns, so call sites that build their own
/// `update_many().col_expr(...)` chain and call sites that thread an
/// `ActiveModel` through this helper see the same binding behavior.
fn simple_expr_for_column<E>(col: E::Column, value: Value, backend: DbBackend) -> SimpleExpr
where
    E: EntityTrait,
{
    // SQLite stores every wrapper value as the marshalled `Value::String`
    // form Phoenix's Ecto adapters expect. No backend-specific casts.
    if backend != DbBackend::Postgres {
        return Expr::val(value);
    }

    // On Postgres, only `Value::String` payloads from the wrapper
    // marshalling layer need cast handling. Non-string variants (Int,
    // Bool, Bytes, etc.) flow through unchanged.
    if !matches!(value, Value::String(_)) {
        return Expr::val(value);
    }

    let col_def = col.def();
    let col_type = col_def.get_column_type();

    // `Value::String(None)` (a SQL NULL on a wrapper-typed column) needs
    // a typed NULL on Postgres. Sending a bare `$N` parameter binds as
    // `text`, which Postgres refuses to assign to a `uuid` / `jsonb` /
    // `text[]` column. The StringArray template specifically would
    // evaluate `ARRAY(SELECT jsonb_array_elements_text(NULL::jsonb))`
    // to `{}` (empty array) rather than NULL, silently corrupting the
    // intended NULL write — so the None branch must short-circuit.
    if matches!(&value, Value::String(None)) {
        if let Some(typed_null) = postgres_typed_null(col_type) {
            return Expr::cust(typed_null);
        }
        return Expr::val(value);
    }

    if let Some(template) = postgres_cast_template(col_type) {
        Expr::cust_with_values(template, vec![value])
    } else {
        Expr::val(value)
    }
}

/// Postgres typed-NULL form (`NULL::uuid`, etc.) for the four wrapper
/// column types. Used by [`simple_expr_for_column`] to write NULL into
/// a wrapper-typed Postgres column without falling foul of the
/// parameter type inference Postgres applies to bare `$N` binds.
fn postgres_typed_null(col_type: &ColumnType) -> Option<&'static str> {
    match col_type {
        ColumnType::Uuid => Some("NULL::uuid"),
        ColumnType::TimestampWithTimeZone => Some("NULL::timestamptz"),
        ColumnType::Json | ColumnType::JsonBinary => Some("NULL::jsonb"),
        ColumnType::Array(inner) => match inner.as_ref() {
            ColumnType::Text | ColumnType::String(_) | ColumnType::Char(_) => Some("NULL::text[]"),
            _ => None,
        },
        _ => None,
    }
}

/// Return the Postgres cast template a wrapper-typed `Value::String`
/// bind needs to land in the column type, or `None` if the column type
/// accepts plain TEXT directly.
///
/// The four templates mirror the wrappers' own
/// `into_simple_expr(backend)` Postgres branches. Keeping them in
/// lockstep is the workspace contract: a wrapper added to
/// `crate::types` adds its cast template here, and the schema-diff
/// CI gate flags entities whose annotation doesn't match.
fn postgres_cast_template(col_type: &ColumnType) -> Option<&'static str> {
    match col_type {
        ColumnType::Uuid => Some("$1::uuid"),
        ColumnType::TimestampWithTimeZone => Some("$1::timestamptz"),
        ColumnType::Json | ColumnType::JsonBinary => Some("$1::jsonb"),
        ColumnType::Array(inner) => match inner.as_ref() {
            // text[] on Postgres is the native form of Phoenix's
            // `{:array, :string}` column shape. The wrapper marshals as
            // a JSON-text array; this template parses that JSON back
            // into a real Postgres array at write time.
            ColumnType::Text | ColumnType::String(_) | ColumnType::Char(_) => {
                Some("ARRAY(SELECT jsonb_array_elements_text($1::jsonb))")
            }
            _ => None,
        },
        _ => None,
    }
}
