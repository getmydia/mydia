# mydia-rs-db

sqlx-backed dual SQLite/Postgres data layer. Talks the Phoenix-created
schema unchanged; mydia-rs never writes a schema migration.

## Query tier policy

Three classes of query exist in mydia-rs. Pick the right tier per query;
the compile-time vs runtime tradeoff is intentional.

### (a) Portable SQL — `sqlx::query_as!` / `sqlx::query!` macros

Use for queries that run unchanged on both engines (most read paths).
The macro talks to a Postgres dev DB at compile time and verifies the
SQL + types against the offline cache under `.sqlx/`. The cache is
committed.

### (b) Dialect-divergent SQL — runtime `sqlx::query` / `sqlx::query_as`

Use for queries that need different SQL per engine: `json_extract` on
SQLite vs `->>` on Postgres, `julianday` vs `EXTRACT(EPOCH ...)`, casts.
Compose the SQL via the helpers in [`mydia_rs_db::dialect`]; runtime
dispatch chooses based on `db.dialect()`. No compile-time SQL check —
the test suite is the safety net.

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
on Postgres. Both encodings round-trip with Ecto's defaults
(`ecto_sqlite3` `:binary_id_type = :string`,
`@default_datetime_type :iso8601`).

## Conversion sweep — tier-(a) macro adoption

The workspace baseline keeps `clippy::disallowed_methods = "allow"` so
unconverted runtime `sqlx::query` / `query_as` / `query_scalar` calls
don't block CI. Each file that finishes its conversion opts in with
`#![warn(clippy::disallowed_methods)]` so backsliding gets flagged.

When every site is either tier-(a) macro or annotated tier-(b), the
workspace baseline flips to `"deny"` and every new query is gated at
compile time.

### Per-call patterns

**Tier (a) — fixed-shape SQL, portable across both engines.**
Pattern (per [`crates/graphql/src/repos/accounts.rs`] and
[`crates/subtitles/src/external.rs`]):

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
            my_value as UuidText  // type annotations as needed
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
using `mydia_rs_db::dialect::json_extract` for cross-engine JSON
access, `QueryBuilder` for runtime-composed WHERE clauses, queries
against SQLite-only tables (`mydia_runtime_lock`) that don't exist
in the PG prepare schema.

```rust
// Reason: SQLite-only table / dynamic filter composition / dialect-divergent JSON.
#[allow(clippy::disallowed_methods)]
sqlx::query("...").bind(...).execute(pool).await?;
```

Every tier-(b) `#[allow]` should carry a one-line reason comment so
future readers know why it's not in the macro tier.

### Aggressive refactor — what unlocks tier (a)

Most "naturally tier (b)" queries become tier (a) after small
type-wrapper refactors:

- **UUID columns**: type the field as `UuidText` (not `String`). The
  wrapper has `sqlx::Type` impls for both engines, so SQL no longer
  needs `id::text AS id` casts.
- **String inputs that are UUIDs**: parse to `UuidText` at the top of
  the function and bind the wrapper. The function signature can keep
  `&str` for caller convenience.
- **`NULLS LAST/FIRST`**: supported on SQLite ≥3.30; safe to use on
  both arms.

Resist macroizing queries where the SQL genuinely diverges. The
`#[allow]` annotation is a valid permanent state when divergence is
real.

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

### Sweep progress

Per-crate conversion state. "Done" = every site is either tier-(a)
macro or tier-(b) `#[allow]`, file-level `#![warn]` opted in, tests
pass, offline build clean.

| Crate | Sites | Status |
|---|---:|---|
| `subtitles` | 4 | done (all 4 → tier (a) via `UuidText` refactor) |
| `events` | ~12 | done (`retention.rs` + `persistence.rs` insert/by-id macroized; dynamic `QueryBuilder` stays for list/count) |
| `app` | 8 | done (PG advisory-lock → macros; SQLite-only `mydia_runtime_lock` table → tier (b)) |
| `models` | 21 | pending |
| `downloads` | 22 | pending |
| `p2p` | 24 | pending |
| `db` | 40 | pending |
| `jobs` | 45 | pending |
| `graphql` | 107 | partial (`repos/accounts.rs` is the original pilot; the rest pending) |
| `web` | 367 | pending |

When the last row flips to "done", flip the workspace lint:
`disallowed_methods = "allow"` → `"deny"` in `mydia-rs/Cargo.toml`'s
`[workspace.lints.clippy]` block. From that point on, every new
runtime `sqlx::query` is a compile error unless explicitly annotated.
