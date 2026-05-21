//! Dual-encoded string array, matching Phoenix's
//! `{:array, :string}` column shape.
//!
//! Phoenix stores these as native `text[]` on Postgres and as JSON-text
//! on `SQLite`. See `priv/repo/migrations/20260223100000_fix_array_columns_for_postgres.exs`
//! for the four columns this applies to: `api_keys.permissions`,
//! `indexer_configs.indexer_ids`, `indexer_configs.categories`,
//! `remote_access_config.direct_urls`.

use serde::{Deserialize, Serialize};
use sqlx::database::Database;
use sqlx::decode::Decode;
use sqlx::encode::{Encode, IsNull};
use sqlx::error::BoxDynError;
use sqlx::{Postgres, Sqlite, Type};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct StringArray(pub Vec<String>);

impl From<Vec<String>> for StringArray {
    fn from(value: Vec<String>) -> Self {
        Self(value)
    }
}

impl From<StringArray> for Vec<String> {
    fn from(value: StringArray) -> Self {
        value.0
    }
}

impl StringArray {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn into_inner(self) -> Vec<String> {
        self.0
    }
}

// ---------- SQLite (TEXT holding a JSON array) ----------

impl Type<Sqlite> for StringArray {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
    fn compatible(ty: &<Sqlite as Database>::TypeInfo) -> bool {
        <String as Type<Sqlite>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Sqlite> for StringArray {
    fn encode_by_ref(
        &self,
        buf: &mut <Sqlite as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        let json = serde_json::to_string(&self.0)?;
        <String as Encode<'q, Sqlite>>::encode_by_ref(&json, buf)
    }
}

impl<'r> Decode<'r, Sqlite> for StringArray {
    fn decode(value: <Sqlite as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let s = <String as Decode<'r, Sqlite>>::decode(value)?;
        let v: Vec<String> = serde_json::from_str(&s)?;
        Ok(Self(v))
    }
}

// ---------- Postgres (native text[]) ----------

impl Type<Postgres> for StringArray {
    fn type_info() -> <Postgres as Database>::TypeInfo {
        <Vec<String> as Type<Postgres>>::type_info()
    }
    fn compatible(ty: &<Postgres as Database>::TypeInfo) -> bool {
        <Vec<String> as Type<Postgres>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Postgres> for StringArray {
    fn encode_by_ref(
        &self,
        buf: &mut <Postgres as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        <Vec<String> as Encode<'q, Postgres>>::encode_by_ref(&self.0, buf)
    }
}

impl<'r> Decode<'r, Postgres> for StringArray {
    fn decode(value: <Postgres as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let inner = <Vec<String> as Decode<'r, Postgres>>::decode(value)?;
        Ok(Self(inner))
    }
}
