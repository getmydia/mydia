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
