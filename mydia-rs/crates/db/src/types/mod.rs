//! `sqlx::Type` impls matching the on-disk format Ecto actually writes.
//!
//! - [`uuid`]: TEXT on SQLite (36-char lowercase hyphenated, per
//!   `ecto_sqlite3`'s `:binary_id_type = :string` default), native
//!   `uuid` on Postgres.
//! - [`datetime`]: RFC3339 with `T` and trailing `Z` on SQLite (per
//!   `ecto_sqlite3`'s `@default_datetime_type :iso8601`), `TIMESTAMPTZ`
//!   on Postgres. Microsecond variants append `.NNNNNN`.
//! - [`json_map`]: arbitrary serializable payload, JSONB on Postgres
//!   and TEXT-JSON on SQLite. Covers Ecto `:map` columns and the
//!   custom Ecto JSON-text types (`Mydia.Library.FileMetadataType`,
//!   etc.).
//! - [`string_array`]: `Vec<String>` round-trip, `text[]` on Postgres
//!   and JSON-text on SQLite. Matches `{:array, :string}` columns per
//!   `priv/repo/migrations/20260223100000_fix_array_columns_for_postgres.exs`.

pub mod datetime;
pub mod json_map;
pub mod string_array;
pub mod uuid;

pub use datetime::{DateTimeMicros, DateTimeSecs};
pub use json_map::JsonMap;
pub use string_array::StringArray;
pub use uuid::UuidText;
