# Model conventions

Quick rules for porting the remaining ~40 Ecto schemas without
re-deriving the same decisions every time.

## File layout

- One struct per Ecto schema, one file per struct.
- File name = snake-cased schema name (`media_item.rs` for `MediaItem`).
- Re-export from `lib.rs`.

## Field naming

- Match Ecto's snake_case verbatim. The GraphQL edge does
  snake-to-camel conversion; the Rust models stay snake_case.
- Use `r#type` for fields literally named `type` (Rust reserved word).

## Column types

| Ecto                       | Rust                                        |
|----------------------------|---------------------------------------------|
| `:string`                  | `String` / `Option<String>`                 |
| `:integer`                 | `i32` (or `i64` for IDs and sizes)          |
| `:boolean`                 | `bool`                                      |
| `:binary_id`               | `mydia_rs_db::types::UuidText`              |
| `:utc_datetime`            | `mydia_rs_db::types::DateTimeSecs`          |
| `:utc_datetime_usec`       | `mydia_rs_db::types::DateTimeMicros`        |
| `:date`                    | `chrono::NaiveDate`                         |
| `:map`                     | `mydia_rs_db::types::JsonMap<T>`            |
| `{:array, :string}`        | `mydia_rs_db::types::StringArray`           |
| Custom JSON-text Ecto type | `mydia_rs_db::types::JsonMap<T>`            |
| `Ecto.Enum` (string-stored)| `String` + sibling Rust enum + `parse(&str)`|

For Ecto string enums and the `:string` validated columns (`User.role`,
`MediaItem.type`), keep the DB column as `String` and add a typed
enum next to the struct with `as_str(self)` and `parse(s: &str) -> Option<Self>`.
This avoids fighting sqlx's per-backend `type_name` quirks and lets the
DB tolerate values from older Phoenix releases without panicking.

## Nullability

- All optional Ecto fields -> `Option<T>`.
- Required Ecto fields with a default -> non-optional. The schema is
  the contract; if a non-nullable column ever turns up null at read
  time, sqlx surfaces it as a decode error and we want to see that.

## Timestamps

- `timestamps(type: :utc_datetime)` -> `inserted_at: DateTimeSecs` +
  `updated_at: DateTimeSecs`.
- `timestamps(type: :utc_datetime, updated_at: false)` -> just
  `inserted_at: DateTimeSecs`.
- The three `:utc_datetime_usec` columns
  (`release_blacklist.expires_at`, `release_blacklist.inserted_at`,
  `download.last_progress_at`) get `DateTimeMicros`.

## Associations

- Don't model `has_many` / `belongs_to` as embedded child collections.
  Each query loads the joins it needs; we're not building an
  ActiveRecord-style lazy-loader.
- Foreign keys live as `UuidText` columns named `<assoc>_id`
  (e.g. `media_item_id`).

## Virtual fields

- Skip them. `password` / `password_confirmation` on `User`, `key` on
  `ApiKey` — none of those touch the DB row; they belong on the
  changeset/form layer in Phoenix and on the auth/CLI layer in Rust.

## sqlx derive

- `#[derive(sqlx::FromRow)]` works cross-backend for any struct whose
  fields implement `Decode` for both `Sqlite` and `Postgres`. All four
  wrapper types in `mydia_rs_db::types` do.

## Tests

- Each model gets one round-trip integration test in
  `crates/models/tests/round_trip.rs`. The test:
  1. Spins up a SQLite pool via `tempfile`.
  2. `CREATE TABLE` matching the columns this struct uses.
  3. Inserts a Rust-built row.
  4. Reads it back via `sqlx::query_as::<_, Model>` and asserts the
     fields round-trip.
- Postgres-side round-trip lives in the db crate's `postgres_smoke.rs`
  for the underlying types; model-level Postgres tests land when the
  model is first exercised by a resolver.
