# mydia-rs-entities

SeaORM entity definitions for the Phoenix-owned schema. One module per
table.

This crate is **server-only**. SeaORM pulls `sqlx`, which is incompatible
with the Dioxus wasm web client per
`reference_mydia_rs_wasm_constraints.md`. Entity types live here rather
than in `mydia-rs-models/` so the wasm tree never tries to compile them.

## Authoring model: entities are hand-written source code

The committed entities (`crates/entities/src/*.rs`) started as a one-time
`sea-orm-cli generate entity` pass against a Phoenix-migrated Postgres
dev DB (commit `05499e40`), then the U2 conversion (commit `25724bb3`)
rewrote them by hand so every cross-engine column points at one of the
wrapper types in `mydia-rs-db/src/types/`. There is no codegen workflow
in the maintained tree — `sea-orm-cli generate entity` does not survive
the wrapper-type rewrite, and re-running it would clobber the
hand-edits.

When Phoenix lands a schema migration, the entity files drift. To
catch up:

1. Identify the changed column from `priv/repo/migrations/`
2. Hand-edit the relevant entity file in `src/`. Pick the appropriate
   wrapper type per the table below.
3. Bump `MAX_KNOWN_MIGRATION` in `crates/db/src/schema_check.rs` to the
   new migration's timestamp.
4. Run `./dev rs schema-diff` locally (Postgres dev DB up). The
   `schema-diff-check` CI job runs the same comparison in CI and fails
   loudly on drift.

## Cross-engine wrappers

Phoenix uses `ecto_sqlite3` and `ecto_postgres` on the same data with
different on-disk encodings. Five column shapes diverge across engines;
each has a wrapper in `mydia-rs-db/src/types/`:

| Wrapper          | SQLite (Ecto)                                | Postgres (Ecto)            | Use for                                          |
|------------------|-----------------------------------------------|-----------------------------|--------------------------------------------------|
| `UuidText`       | TEXT, 36-char lowercase-hyphenated           | native `uuid`               | `binary_id` primary keys / FKs                   |
| `DateTimeSecs`   | TEXT, RFC3339 + `Z`, second precision        | `TIMESTAMPTZ`               | `:utc_datetime` columns                          |
| `DateTimeMicros` | TEXT, RFC3339 + `Z` + `.NNNNNN`, µs precision| `TIMESTAMPTZ`               | `:utc_datetime_usec` columns                     |
| `JsonMap<T>`     | TEXT holding JSON                            | `JSONB`                     | `:map` columns + Jason-encoded custom types      |
| `StringArray`    | TEXT holding JSON array                      | `text[]`                    | `{:array, :string}` columns                      |

Each wrapper carries `From<W> for Value` + an engine-branched
`TryGetable` impl + an `into_simple_expr(backend) -> SimpleExpr` write
helper. Reads go through SeaORM's `Entity::find()` unchanged. Writes
against wrapper-typed columns go through `mydia_rs_db::insert_active_model`
(or `update_active_model`), which inspects the column's `ColumnDef`
and applies the engine-appropriate cast template. Vanilla
`ActiveModelTrait::insert` / `update` are forbidden by the workspace
`clippy.toml` — they cannot inject the Postgres casts that uuid /
timestamptz / jsonb / text[] columns require for a `Value::String`
bind.

The `Statement::from_sql_and_values` and `raw_sql!` macros are
forbidden in landed code, as is `Expr::cust_with_values` outside
`crates/db/src/types/`. The schema-diff-check CI job enforces entity
correctness against the Phoenix-Postgres schema.

## Cross-references

- `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`
  is the design record. Start there for any non-trivial change.
- `crates/db/README.md` documents the wrapper-type API and the
  `insert_active_model` / `update_active_model` write helpers.
- The 2026-05-24 spike (memory `seaorm_wrapper_type_impasse.md`)
  records why a single context-free `From<T> for Value` impl cannot
  satisfy both engines and why the wrapper helper + workspace insert
  helper combo is the smallest shape that works.
