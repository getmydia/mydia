//! Dual-encoded string array, matching Phoenix's
//! `{:array, :string}` column shape.
//!
//! Phoenix stores these as native `text[]` on Postgres and as JSON-text
//! on `SQLite`. See `priv/repo/migrations/20260223100000_fix_array_columns_for_postgres.exs`
//! for the four columns this applies to: `api_keys.permissions`,
//! `indexer_configs.indexer_ids`, `indexer_configs.categories`,
//! `remote_access_config.direct_urls`.

use sea_orm::sea_query::{
    ArrayType, ColumnType, Expr, Nullable, SimpleExpr, StringLen, Value, ValueType, ValueTypeErr,
};
use sea_orm::{ColIdx, DbBackend, DbErr, QueryResult, TryGetError, TryGetable};
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

// ---------- SeaORM (engine-aware via wrapper helpers) ----------
//
// Most divergent wrapper. Marshals as `Value::String` containing a JSON
// array; writes against Postgres `text[]` columns add `$N::text[]` plus
// a JSON-to-array coercion (Postgres treats the cast as text-to-array
// only when the input is in Postgres array literal form, which JSON is
// not — so the cast goes through a small `regexp_replace` to swap `[…]`
// brackets for `{…}` and unquote scalar elements). On SQLite the JSON
// text is the canonical on-disk form so a plain string bind suffices.
//
// The Postgres branch deliberately does NOT use `Vec<String>` natively.
// SeaORM's `Value::Array` requires `feature = "postgres-array"` which
// pulls in sqlx's bespoke array encoder; routing every wrapper through
// `Value::String` keeps the marshalling layer uniform and avoids the
// "two SeaORM `Value` variants for one column type" trap the spike
// surfaced for UUID.

impl From<StringArray> for Value {
    fn from(value: StringArray) -> Self {
        let s = serde_json::to_string(&value.0).unwrap_or_else(|_| "[]".to_string());
        Value::String(Some(s))
    }
}

impl ValueType for StringArray {
    fn try_from(v: Value) -> Result<Self, ValueTypeErr> {
        match v {
            Value::String(Some(s)) => serde_json::from_str::<Vec<String>>(&s)
                .map(Self)
                .map_err(|_| ValueTypeErr),
            _ => Err(ValueTypeErr),
        }
    }

    fn type_name() -> String {
        "StringArray".to_string()
    }

    fn array_type() -> ArrayType {
        ArrayType::String
    }

    fn column_type() -> ColumnType {
        // On Postgres this column is declared as `text[]`; on SQLite as
        // TEXT-holding-JSON. We pick the SQLite-friendly column type here
        // because entities override it at the column-annotation level
        // (`column_type = "Array(Text)"`) for the Postgres dialect, and
        // `Schema::create_table_from_entity` consults the annotation, not
        // this fallback.
        ColumnType::String(StringLen::None)
    }
}

impl Nullable for StringArray {
    fn null() -> Value {
        Value::String(None)
    }
}

impl TryGetable for StringArray {
    fn try_get_by<I: ColIdx>(res: &QueryResult, idx: I) -> Result<Self, TryGetError> {
        if res.try_as_pg_row().is_some() {
            // Postgres `text[]` surfaces natively as `Vec<String>` —
            // pull it out via SeaORM's built-in postgres-array TryGetable.
            <Vec<String> as TryGetable>::try_get_by(res, idx).map(Self)
        } else {
            let s = <String as TryGetable>::try_get_by(res, idx)?;
            serde_json::from_str::<Vec<String>>(&s)
                .map(Self)
                .map_err(|e| {
                    TryGetError::DbErr(DbErr::Type(format!("invalid StringArray (SQLite): {e}")))
                })
        }
    }
}

impl StringArray {
    /// `SeaORM` `SimpleExpr` that binds this string array against
    /// either engine. `SQLite` gets the JSON-text form (matching
    /// Phoenix's on-disk shape). Postgres gets the JSON-to-array
    /// coercion that satisfies the schema's native `text[]` column
    /// without relying on `SeaORM`'s `Value::Array` variant (which only
    /// travels through the `postgres-array` feature pathway and adds
    /// binding asymmetry the other wrappers don't).
    ///
    /// The coercion uses Postgres's `json_array_elements_text` view:
    /// `ARRAY(SELECT jsonb_array_elements_text($1::jsonb))`. This works
    /// for arbitrary JSON-string-array payloads including the empty
    /// array case.
    pub fn into_simple_expr(self, backend: DbBackend) -> SimpleExpr {
        let s = serde_json::to_string(&self.0).unwrap_or_else(|_| "[]".to_string());
        match backend {
            DbBackend::Sqlite => SimpleExpr::Value(Value::String(Some(s))),
            DbBackend::Postgres => Expr::cust_with_values(
                "ARRAY(SELECT jsonb_array_elements_text($1::jsonb))",
                vec![Value::String(Some(s))],
            ),
            DbBackend::MySql => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
            _ => unreachable!(
                "unknown DbBackend variant; mydia-rs is dual-engine SQLite/Postgres only"
            ),
        }
    }
}
