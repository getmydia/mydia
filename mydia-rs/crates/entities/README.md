# mydia-rs-entities

SeaORM entity definitions for the Phoenix-owned schema. One module per
table, generated from a live, Phoenix-migrated Postgres dev database via
`sea-orm-cli`. Treated as source code after the first generation pass —
the operator script-patches columns onto the workspace's cross-engine
type wrappers (see [Cross-engine wrappers](#cross-engine-wrappers)) and
those patches re-apply idempotently after a regeneration.

This crate is **server-only**. SeaORM pulls `sqlx`, which is incompatible
with the Dioxus wasm web client per
`reference_mydia_rs_wasm_constraints.md`. Entity types live here rather
than in `mydia-rs-models/` so the wasm tree never tries to compile them.

## Regenerating entities

When Phoenix lands a schema migration, mydia-rs's entities drift. The
regeneration workflow:

```bash
# 1. Bring up the dev Postgres if it isn't already running.
docker compose --profile postgres up -d postgres

# 2. Apply the latest Phoenix migrations against the dev DB.
./dev mix ecto.migrate

# 3. Regenerate entities. The script wraps sea-orm-cli + the
#    script-patch in a single command. Until U5 lands the wrapper, run
#    the underlying tool directly:
DATABASE_URL="postgres://postgres:postgres@localhost:5433/mydia_dev" \
  sea-orm-cli generate entity \
    --output-dir mydia-rs/crates/entities/src \
    --with-serde both \
    --lib

# 4. Re-apply the type-wrapper patches (U3). Idempotent — running
#    against an unchanged schema produces no diff.
bash mydia-rs/crates/entities/src/_patch.sh

# 5. Verify entities compile and commit.
cd mydia-rs && cargo check -p mydia-rs-entities
git add mydia-rs/crates/entities/src/
git commit -m "chore(mydia-rs): regenerate entities for <reason>"
```

CI's `entity-drift-check` job (U5) runs the same steps and fails the
build when the committed entities don't match what Phoenix's current
schema would generate. If your branch fails this check, regenerate
locally and commit the diff.

## Cross-engine wrappers

`sea-orm-cli` generates entities with native Postgres types
(`Uuid`, `DateTime`, `Vec<String>`, `serde_json::Value`). mydia-rs serves
both Postgres and SQLite, and four wrapper types in `mydia-rs-db::types`
reconcile the dialect divergence at the column-type level:

| Wrapper | Replaces | Postgres encoding | SQLite encoding |
|---|---|---|---|
| `UuidText` | `Uuid` | native `uuid` | TEXT |
| `DateTimeSecs` | `DateTime` (sec precision) | `TIMESTAMPTZ` | RFC3339-Z TEXT |
| `DateTimeMicros` | `DateTime` (µs precision) | `TIMESTAMPTZ` | RFC3339-Z+µs TEXT |
| `JsonMap<T>` | `serde_json::Value` (whole-struct only) | `JSONB` | TEXT-JSON |
| `StringArray` | `Vec<String>` | `text[]` | TEXT-JSON-array |

The script-patch in `src/_patch.sh` rewrites the generated column types
to use these wrappers wherever the existing schema requires cross-engine
parity (the four `StringArray` columns are enumerated in the plan; the
UUID and timestamp columns are detected by Postgres column type during
the script-patch sweep).

### What never goes in this crate

- **Hand-written entities for mydia-rs-owned tables** — the `mydia_runtime_lock`
  SQLite-only table lives here as the documented exception. It is *not*
  generated; it is hand-defined because Phoenix's Postgres has no
  corresponding table. The CI drift check ignores it.
- **JSON-path predicates** — SeaORM does not abstract `json_extract`
  (SQLite) vs `->>` (Postgres). Per the unification plan's Key
  Decisions, JSON columns are read/written whole and filtered in Rust.
- **Raw SQL escape hatches** — `Statement::from_sql_and_values`,
  `raw_sql!`, and `Expr::cust_with_values` are forbidden in landed code.
  Queries that can't be expressed via SeaORM's typed builder get a
  design change (denormalize, fetch + filter, generated column), not a
  raw-SQL fallback.

See `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`
for the full destination-shape policy.
