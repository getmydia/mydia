//! `sqlx::Type` impls matching the on-disk format Ecto actually writes.
//!
//! - [`uuid`]: TEXT on SQLite (36-char lowercase hyphenated, per
//!   `ecto_sqlite3`'s `:binary_id_type = :string` default), native
//!   `uuid` on Postgres.
//! - [`datetime`]: RFC3339 with `T` and trailing `Z` on SQLite (per
//!   `ecto_sqlite3`'s `@default_datetime_type :iso8601`), `TIMESTAMPTZ`
//!   on Postgres. Microsecond variants append `.NNNNNN`.
//!
//! JSON variants (`:map` -> JSONB on Postgres / TEXT on SQLite, and
//! `:text` carrying Jason-encoded payloads -> TEXT on both) land in U5
//! when the first model needs them.

pub mod datetime;
pub mod uuid;

pub use datetime::{DateTimeMicros, DateTimeSecs};
pub use uuid::UuidText;
