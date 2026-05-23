//! Ecto-schema-equivalent Rust structs. First batch (U5):
//!
//! - [`user::User`]
//! - [`api_key::ApiKey`]
//! - [`media_item::MediaItem`]
//! - [`episode::Episode`]
//! - [`media_file::MediaFile`]
//! - [`library_path::LibraryPath`]
//!
//! See `crates/models/src/conventions.md` for the rules covering the
//! remaining ~40 schemas. Common surface:
//!
//! - `snake_case` field names, matching Ecto. async-graphql does
//!   snake -> camel conversion at the API edge.
//! - UUID primary keys and foreign keys use [`mydia_rs_db::types::UuidText`].
//! - `:utc_datetime` columns use [`mydia_rs_db::types::DateTimeSecs`];
//!   `:utc_datetime_usec` uses [`mydia_rs_db::types::DateTimeMicros`].
//! - `:map` columns and Ecto custom JSON-text types use
//!   [`mydia_rs_db::types::JsonMap`] with a typed payload, or
//!   `serde_json::Value` while the concrete struct is still being ported.
//! - `{:array, :string}` columns use [`mydia_rs_db::types::StringArray`].
//! - Ecto `Ecto.Enum` and string-validated columns map to Rust enums
//!   exposed alongside the struct; the DB column itself stays `String`
//!   to avoid sqlx-derive `type_name` mismatches between `SQLite` TEXT
//!   and Postgres TEXT.

pub mod api_key;
pub mod episode;
pub mod library_path;
pub mod media_file;
pub mod media_item;
pub mod pairing_claim;
pub mod remote_device;
pub mod user;

pub use api_key::ApiKey;
pub use episode::Episode;
pub use library_path::LibraryPath;
pub use media_file::MediaFile;
pub use media_item::MediaItem;
pub use pairing_claim::PairingClaim;
pub use remote_device::RemoteDevice;
pub use user::User;
