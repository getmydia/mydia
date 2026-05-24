//! `sqlx::Type` for JSON-shaped columns that round-trip across engines.
//!
//! Two Ecto column shapes both fit this type:
//!
//! 1. `:map` columns (e.g. `library_paths.category_paths`). Postgres
//!    stores them as `JSONB`; `SQLite` stores them as TEXT containing a
//!    JSON object.
//! 2. Custom Ecto types holding Jason-encoded payloads (e.g.
//!    `Mydia.Library.FileMetadataType`). Postgres stores those as TEXT
//!    too in our schema (the custom type controls the encode), so the
//!    same wrapper works for both — `JsonMap<T>` just means "this
//!    column is JSON we round-trip via serde".
//!
//! The wrapper uses `serde_json`'s default key ordering on the way out.
//! Phoenix and mydia-rs need not produce byte-identical JSON because
//! every read happens via `json_extract` / `->>`, never by string
//! equality.

use sea_orm::sea_query::{
    ArrayType, ColumnType, Expr, Nullable, SimpleExpr, Value, ValueType, ValueTypeErr,
};
use sea_orm::{ColIdx, DbBackend, DbErr, QueryResult, TryGetError, TryGetable};
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

// ---------- SeaORM (engine-aware via wrapper helpers) ----------
//
// `JsonMap<T>` marshals as a serialized JSON string in `Value::String`
// (uniform across engines for the bind side); writes against Postgres
// JSONB columns add the `$N::jsonb` cast in
// [`JsonMap::into_simple_expr`]. Reads engine-branch — Postgres reads
// the column as a `serde_json::Value` (the JSONB native form sea-orm
// surfaces) and re-decodes into `T`; SQLite reads the TEXT and runs
// `serde_json::from_str` directly.

impl<T> From<JsonMap<T>> for Value
where
    T: Serialize,
{
    fn from(value: JsonMap<T>) -> Self {
        // `From` must be infallible; serde_json::to_string can in theory
        // fail on cycles or unsupported types, but every `T` we route
        // through `JsonMap` is well-formed serde data. Fall back to an
        // empty JSON object so the bind still produces a valid TEXT
        // payload even in the degenerate case.
        let s = serde_json::to_string(&value.0).unwrap_or_else(|_| "{}".to_string());
        Value::String(Some(s))
    }
}

impl<T> ValueType for JsonMap<T>
where
    T: Serialize + DeserializeOwned,
{
    fn try_from(v: Value) -> Result<Self, ValueTypeErr> {
        match v {
            Value::String(Some(s)) => serde_json::from_str(&s).map(Self).map_err(|_| ValueTypeErr),
            _ => Err(ValueTypeErr),
        }
    }

    fn type_name() -> String {
        format!("JsonMap<{}>", std::any::type_name::<T>())
    }

    fn array_type() -> ArrayType {
        ArrayType::String
    }

    fn column_type() -> ColumnType {
        ColumnType::JsonBinary
    }
}

impl<T> Nullable for JsonMap<T> {
    fn null() -> Value {
        Value::String(None)
    }
}

impl<T> TryGetable for JsonMap<T>
where
    T: Serialize + DeserializeOwned,
{
    fn try_get_by<I: ColIdx>(res: &QueryResult, idx: I) -> Result<Self, TryGetError> {
        if res.try_as_pg_row().is_some() {
            // Postgres JSONB surfaces through sea-orm as `serde_json::Value`;
            // re-decode into the concrete `T` so the wrapper stays generic
            // over arbitrary payload shapes.
            let raw = <serde_json::Value as TryGetable>::try_get_by(res, idx)?;
            serde_json::from_value(raw).map(Self).map_err(|e| {
                TryGetError::DbErr(DbErr::Type(format!("invalid JsonMap (Postgres): {e}")))
            })
        } else {
            let s = <String as TryGetable>::try_get_by(res, idx)?;
            serde_json::from_str(&s).map(Self).map_err(|e| {
                TryGetError::DbErr(DbErr::Type(format!("invalid JsonMap (SQLite): {e}")))
            })
        }
    }
}

impl<T> JsonMap<T>
where
    T: Serialize,
{
    /// `SeaORM` `SimpleExpr` that binds the serialized JSON payload
    /// with the engine-appropriate cast — `::jsonb` on Postgres so a
    /// string parameter can target a `JSONB` column, plain TEXT on
    /// `SQLite`.
    pub fn into_simple_expr(self, backend: DbBackend) -> SimpleExpr {
        let s = serde_json::to_string(&self.0).unwrap_or_else(|_| "{}".to_string());
        match backend {
            DbBackend::Sqlite => SimpleExpr::Value(Value::String(Some(s))),
            DbBackend::Postgres => {
                Expr::cust_with_values("$1::jsonb", vec![Value::String(Some(s))])
            }
            DbBackend::MySql => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
            _ => unreachable!(
                "unknown DbBackend variant; mydia-rs is dual-engine SQLite/Postgres only"
            ),
        }
    }
}
