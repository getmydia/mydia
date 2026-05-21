//! UUID encoding that matches Ecto's `:binary_id` on-disk format.
//!
//! Phoenix uses `ecto_sqlite3`'s default `:binary_id_type = :string`,
//! which stores UUIDs as 36-character lowercase-hyphenated TEXT on
//! SQLite (e.g. `0186fa3d-1c2f-7c4f-9aaa-1234567890ab`). Postgres uses
//! the native `uuid` type. sqlx's built-in `Uuid` Type stores BLOB on
//! SQLite, which would corrupt cross-backend reads, so we wrap with
//! [`UuidText`] and route the SQLite path through TEXT.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use sqlx::database::Database;
use sqlx::decode::Decode;
use sqlx::encode::{Encode, IsNull};
use sqlx::error::BoxDynError;
use sqlx::{Postgres, Sqlite, Type};
use uuid::Uuid;

/// Newtype wrapper around [`uuid::Uuid`] that encodes as TEXT on SQLite
/// and as the native `uuid` type on Postgres.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(transparent)]
pub struct UuidText(pub Uuid);

impl UuidText {
    pub fn new_v4() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for UuidText {
    fn from(value: Uuid) -> Self {
        Self(value)
    }
}

impl From<UuidText> for Uuid {
    fn from(value: UuidText) -> Self {
        value.0
    }
}

impl fmt::Display for UuidText {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.as_hyphenated())
    }
}

impl FromStr for UuidText {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Uuid::parse_str(s).map(Self)
    }
}

// ---------- SQLite (TEXT) ----------

impl Type<Sqlite> for UuidText {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }

    fn compatible(ty: &<Sqlite as Database>::TypeInfo) -> bool {
        <String as Type<Sqlite>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Sqlite> for UuidText {
    fn encode_by_ref(
        &self,
        buf: &mut <Sqlite as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        // Lowercase hyphenated form (Ecto convention).
        let s = self.0.as_hyphenated().to_string();
        <String as Encode<'q, Sqlite>>::encode_by_ref(&s, buf)
    }
}

impl<'r> Decode<'r, Sqlite> for UuidText {
    fn decode(value: <Sqlite as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let s = <String as Decode<'r, Sqlite>>::decode(value)?;
        Ok(Self(Uuid::parse_str(&s)?))
    }
}

// ---------- Postgres (native uuid) ----------

impl Type<Postgres> for UuidText {
    fn type_info() -> <Postgres as Database>::TypeInfo {
        <Uuid as Type<Postgres>>::type_info()
    }

    fn compatible(ty: &<Postgres as Database>::TypeInfo) -> bool {
        <Uuid as Type<Postgres>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Postgres> for UuidText {
    fn encode_by_ref(
        &self,
        buf: &mut <Postgres as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        <Uuid as Encode<'q, Postgres>>::encode_by_ref(&self.0, buf)
    }
}

impl<'r> Decode<'r, Postgres> for UuidText {
    fn decode(value: <Postgres as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let inner = <Uuid as Decode<'r, Postgres>>::decode(value)?;
        Ok(Self(inner))
    }
}
