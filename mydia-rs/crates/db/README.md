# mydia-rs-db

Dual SQLite/Postgres data layer. Mid-cutover between two surfaces:

- **Legacy (Phase A coexistence):** sqlx-backed `Db` enum, with the
  tier-(a) macro / tier-(b) `#[allow]` policy below.
- **Destination (post-U6):** SeaORM 2.0 `DatabaseConnection`, with the
  cross-engine wrapper types in [`types`] and the engine-aware
  [`insert_active_model`] / [`update_active_model`] write helpers.

Talks the Phoenix-created schema unchanged; mydia-rs never writes a
schema migration.

## SeaORM cutover

See `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`
for the full plan. Active Phase A units land alongside the legacy
sqlx layer; Phase B's U6 cutover deletes the `Db` enum and switches
every consumer to threading a SeaORM `DatabaseConnection`.

The wrappers in [`types`] are the load-bearing piece: each carries
both legacy `sqlx::Type` impls and SeaORM-native
`DeriveValueType<String>` + engine-branched `TryGetable` + an
`into_simple_expr(backend)` write helper. Writes to any
wrapper-typed column flow through [`insert_active_model`] /
[`update_active_model`] in [`crate::insert_helper`] so the
`$N::uuid` / `$N::timestamptz` / `$N::jsonb` /
`ARRAY(SELECT jsonb_array_elements_text($N::jsonb))` casts land on
Postgres while SQLite gets the Ecto-compat TEXT form.

`clippy.toml` denies vanilla `sea_orm::ActiveModelTrait::insert` and
`::update` workspace-wide so Phase B per-crate units cannot bypass
the helper.

## Query tier policy (legacy sqlx — applies until U6)

Two classes of query exist in the unconverted sqlx layer. Pick the
right tier per query; the compile-time vs runtime tradeoff is
intentional.

### (a) Portable SQL — `sqlx::query_as!` / `sqlx::query!` macros

Use for queries that run unchanged on both engines (most read paths).
The macro talks to a Postgres dev DB at compile time and verifies the
SQL + types against the offline cache under `.sqlx/`. The cache is
committed.

### (b) Dialect-divergent SQL — runtime `sqlx::query` / `sqlx::query_as`

Use for queries that need different SQL per engine: `json_extract` on
SQLite vs `->>` on Postgres, `julianday` vs `EXTRACT(EPOCH ...)`,
casts. Compose the SQL inline at the call site with engine-branched
arms; no shared dialect helper module — the previous
`mydia_rs_db::dialect` helpers were deleted in U4 once zero external
consumers remained. Runtime dispatch chooses based on the `Db` enum
variant. No compile-time SQL check — the test suite is the safety
net.

### (c) Schema migrations

mydia-rs never writes one. Phoenix owns `priv/repo/migrations/`. The
`schema_check` probe at boot enforces the version contract.

## `SELECT *` is forbidden

Always enumerate columns. Additive Phoenix migrations must not surprise
mydia-rs; explicit column lists keep new columns from leaking into
deserialization paths that don't expect them.

## On-disk type encoding

See [`mydia_rs_db::types`]. UUIDs are TEXT-on-SQLite and native uuid
on Postgres; UTC datetimes are RFC3339-Z on SQLite and `TIMESTAMPTZ`
on Postgres. JSON columns are TEXT-JSON on SQLite and `JSONB` on
Postgres. `{:array, :string}` columns are TEXT-JSON-array on SQLite
and `text[]` on Postgres. Every encoding round-trips with Ecto's
defaults (`ecto_sqlite3` `:binary_id_type = :string`,
`@default_datetime_type :iso8601`).

## Conversion sweep — tier-(a) macro adoption

The workspace baseline is `clippy::disallowed_methods = "deny"`, so
unconverted runtime `sqlx::query` / `query_as` / `query_scalar` calls
fail CI. Per-call `#[allow(clippy::disallowed_methods)]` annotations
suppress with a one-line reason — used for dialect-divergent SQL and
dynamic SQL composition.

The SeaORM unification plan supersedes the strict-zero sqlx tier-(a)
sweep: every site eventually becomes a SeaORM call, and the
`disallowed_methods` lint will then also disallow vanilla
`ActiveModelTrait::insert` / `::update` for wrapper-touched tables.

### Per-call patterns (legacy)

**Tier (a) — fixed-shape SQL, portable across both engines.**

```rust
match db {
    Db::Sqlite(pool) => {
        // SQLite arm: runtime form. SQL is byte-equal to the Postgres
        // macro arm; sqlx-sqlite accepts $N placeholders.
        #[allow(clippy::disallowed_methods)]
        sqlx::query_as::<_, MyRow>(
            "SELECT ... FROM ... WHERE x = $1"
        )
        .bind(my_value)
        .fetch_all(pool)
        .await
    }
    Db::Postgres(pool) => {
        sqlx::query_as!(
            MyRow,
            r#"SELECT ... FROM ... WHERE x = $1"#,
            my_value as UuidText
        )
        .fetch_all(pool)
        .await
    }
}
```

The two arms MUST have byte-equal SQL. When the Postgres macro
compiles against `cargo sqlx prepare --workspace`, the SQLite arm
is correct by construction.

**Tier (b) — dialect-divergent or dynamic SQL.** Examples: queries
using `json_extract` for cross-engine JSON access on SQLite vs `->>`
on Postgres, `QueryBuilder` for runtime-composed WHERE clauses,
queries against SQLite-only tables (`mydia_runtime_lock`) that don't
exist in the PG prepare schema.

```rust
// Reason: SQLite-only table / dynamic filter composition / dialect-divergent JSON.
#[allow(clippy::disallowed_methods)]
sqlx::query("...").bind(...).execute(pool).await?;
```

Every tier-(b) `#[allow]` should carry a one-line reason comment so
future readers know why it's not in the macro tier.

### Regenerating the `.sqlx/` offline cache

Every new macro call needs a corresponding entry. Bring up Postgres
(`docker compose --profile postgres up -d postgres`), apply Phoenix's
migrations once, then run:

```
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/mydia_dev \
  ./dev rs sqlx-prepare
```

Commit every new `mydia-rs/.sqlx/query-*.json` file. CI builds with
`SQLX_OFFLINE=true` against the cache; no live DB needed.

The `.sqlx/` cache and the `sqlx-prepare-check` CI job both go away
in U19 once the SeaORM cutover completes.
