//! `sqlx::Type` for JSON-shaped columns that round-trip across engines.
//!
//! Two Ecto column shapes both fit this type:
//!
//! 1. `:map` columns (e.g. `library_paths.category_paths`). Postgres
//!    stores them as `JSONB`; SQLite stores them as TEXT containing a
//!    JSON object.
//! 2. Custom Ecto types holding Jason-encoded payloads (e.g.
//!    `Mydia.Library.FileMetadataType`). Postgres stores those as TEXT
//!    too in our schema (the custom type controls the encode), so the
//!    same wrapper works for both — `JsonMap<T>` just means "this
//!    column is JSON we round-trip via serde".
//!
//! The wrapper uses serde_json's default key ordering on the way out.
//! Phoenix and mydia-rs need not produce byte-identical JSON because
//! every read happens via `json_extract` / `->>`, never by string
//! equality.

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sqlx::database::Database;
use sqlx::decode::Decode;
use sqlx::encode::{Encode, IsNull};
use sqlx::error::BoxDynError;
use sqlx::{Postgres, Sqlite, Type};

/// Newtype around an arbitrary serializable payload stored as JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct JsonMap<T>(pub T);

impl<T> JsonMap<T> {
    pub fn new(value: T) -> Self {
        Self(value)
    }

    pub fn into_inner(self) -> T {
        self.0
    }
}

impl<T> From<T> for JsonMap<T> {
    fn from(value: T) -> Self {
        Self(value)
    }
}

// ---------- SQLite (TEXT holding JSON) ----------

impl<T> Type<Sqlite> for JsonMap<T> {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
    fn compatible(ty: &<Sqlite as Database>::TypeInfo) -> bool {
        <String as Type<Sqlite>>::compatible(ty)
    }
}

impl<'q, T> Encode<'q, Sqlite> for JsonMap<T>
where
    T: Serialize,
{
    fn encode_by_ref(
        &self,
        buf: &mut <Sqlite as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        let json = serde_json::to_string(&self.0)?;
        <String as Encode<'q, Sqlite>>::encode_by_ref(&json, buf)
    }
}

impl<'r, T> Decode<'r, Sqlite> for JsonMap<T>
where
    T: DeserializeOwned,
{
    fn decode(value: <Sqlite as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let s = <String as Decode<'r, Sqlite>>::decode(value)?;
        let v: T = serde_json::from_str(&s)?;
        Ok(Self(v))
    }
}

// ---------- Postgres (native JSONB) ----------

impl<T> Type<Postgres> for JsonMap<T> {
    fn type_info() -> <Postgres as Database>::TypeInfo {
        <sqlx::types::Json<T> as Type<Postgres>>::type_info()
    }
    fn compatible(ty: &<Postgres as Database>::TypeInfo) -> bool {
        <sqlx::types::Json<T> as Type<Postgres>>::compatible(ty)
    }
}

impl<'q, T> Encode<'q, Postgres> for JsonMap<T>
where
    T: Serialize,
{
    fn encode_by_ref(
        &self,
        buf: &mut <Postgres as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        let wrapped = sqlx::types::Json(&self.0);
        <sqlx::types::Json<&T> as Encode<'q, Postgres>>::encode_by_ref(&wrapped, buf)
    }
}

impl<'r, T> Decode<'r, Postgres> for JsonMap<T>
where
    T: DeserializeOwned + 'r,
{
    fn decode(value: <Postgres as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let inner = <sqlx::types::Json<T> as Decode<'r, Postgres>>::decode(value)?;
        Ok(Self(inner.0))
    }
}
