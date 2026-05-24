# mydia-rs-db

Workspace data layer: SeaORM 2.x connection bootstrap, cross-engine
wrapper types, and the write helpers every consumer crate threads
its `ActiveModel` writes through.

## Public surface

```rust
pub use mydia_rs_db::{
    connect_from_config,           // returns sea_orm::DatabaseConnection
    insert_active_model,           // workspace INSERT helper
    update_active_model,           // workspace UPDATE helper
    schema_check, MAX_KNOWN_MIGRATION, SchemaCheckOutcome,
    DatabaseConnection,            // re-export of sea_orm::DatabaseConnection
    DbError,
};

pub use mydia_rs_db::types::{
    UuidText,        // ecto-compat lowercase-hyphenated TEXT on SQLite, native uuid on PG
    DateTimeSecs,    // RFC3339-Z TEXT on SQLite, TIMESTAMPTZ on PG (Ecto :utc_datetime)
    DateTimeMicros,  // RFC3339-Z.NNNNNN TEXT on SQLite, TIMESTAMPTZ on PG (Ecto :utc_datetime_usec)
    JsonMap,         // serde-serialized payload, TEXT-JSON on SQLite, JSONB on PG
    StringArray,     // JSON-text array on SQLite, native text[] on PG
};
```

## Architecture

`pool::connect_from_config` opens a SeaORM `DatabaseConnection`. PRAGMAs
on SQLite flow through `ConnectOptions::map_sqlx_sqlite_opts`; pool
sizing is shared across engines via `ConnectOptions::max_connections` /
`acquire_timeout`. There is no `Db` enum, no `from_sqlx_*_pool`
bridging seam, and no per-engine accessor. Downstream crates thread
`&DatabaseConnection` everywhere and stay dialect-agnostic.

Engine awareness lives in two contained surfaces:

1. **Wrapper types** (`crate::types`). Each wrapper carries
   `From<W> for Value`, a custom engine-branched `TryGetable`, and an
   `into_simple_expr(self, backend: DbBackend) -> SimpleExpr` write
   helper. The latter is the *one* location in landed code where
   `Expr::cust_with_values` is permitted — it emits `$N::uuid`,
   `$N::timestamptz`, `$N::jsonb`, or the `ARRAY(SELECT
   jsonb_array_elements_text($1::jsonb))` cast on Postgres while
   falling through to a plain `Value::String` bind on SQLite.

2. **Insert / update helpers** (`crate::insert_helper`).
   `insert_active_model<A>(am, db)` consumes any `ActiveModelTrait`
   value, inspects each `Set` field's column-type annotation, and
   applies the engine-appropriate cast template. Vanilla
   `ActiveModelTrait::insert` is forbidden by the workspace
   `clippy.toml` — it has no `DbBackend` parameter and so cannot
   inject the casts the 2026-05-24 spike proved are mandatory on PG
   for wrapper-typed columns. Same story for `update_active_model`.

## Common patterns

### Read

```rust
use mydia_rs_db::types::UuidText;
use mydia_rs_entities::media_items;
use sea_orm::{ColumnTrait, EntityTrait, QueryFilter};
use sea_orm::sea_query::{Expr, ExprTrait};

let backend = db.get_database_backend();
let model = media_items::Entity::find()
    .filter(Expr::col(media_items::Column::Id).eq(id.into_simple_expr(backend)))
    .one(db)
    .await?;
```

For non-wrapper columns the vanilla `Column::X.eq(value)` shape works
unchanged. Use the `Expr::col(...)` form only when the RHS is a
`SimpleExpr` (which is what `into_simple_expr` returns).

### Write — full-row INSERT

```rust
use mydia_rs_db::{insert_active_model, types::{DateTimeSecs, UuidText}};
use mydia_rs_entities::media_items;
use sea_orm::Set;

let am = media_items::ActiveModel {
    id: Set(UuidText::new_v4()),
    title: Set("Inception".to_string()),
    inserted_at: Set(DateTimeSecs::from(chrono::Utc::now())),
    ..Default::default()
};
let model = insert_active_model(am, db).await?;
```

### Write — sparse column UPDATE

```rust
use sea_orm::{ColumnTrait, EntityTrait, QueryFilter};
use sea_orm::sea_query::{Expr, ExprTrait};

let backend = db.get_database_backend();
media_items::Entity::update_many()
    .col_expr(media_items::Column::Title, Expr::value("new title"))
    .filter(Expr::col(media_items::Column::Id).eq(id.into_simple_expr(backend)))
    .exec(db)
    .await?;
```

For wrapper-typed targets use `wrapper.into_simple_expr(backend)` in
`col_expr` instead of `Expr::value`.

### Boot-time DDL

`Schema::new(backend).create_table_from_entity(entity)` emits
dialect-correct `CREATE TABLE`. See `mydia_runtime_lock`'s
`ensure_lock_table` for the canonical pattern.

### Test fixtures

Schema bootstrap via `Schema::create_table_from_entity` + the workspace
insert helper. Hand-write the DDL for `Array(Text)` columns on SQLite
(SeaORM's SQLite DDL backend panics on `Array(_)`); plain `TEXT` is
the matching Phoenix Ecto-JSON-text shape. `PRAGMA foreign_keys = OFF`
on test connections where FK enforcement trips on out-of-scope
sibling tables. The `crates/graphql/tests/common/mod.rs` helper is the
worked example.

## Cross-references

- `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`
  is the design record for the SeaORM adoption sweep. Reviewer
  audiences should start there.
- `crates/entities/README.md` documents the entity hand-edit workflow.
- The 2026-05-24 wrapper spike (memory
  `seaorm_wrapper_type_impasse.md`) records why engine awareness has
  to live somewhere — context for anyone tempted to "simplify" the
  wrapper layer back into a context-free `From<T> for Value` impl.
