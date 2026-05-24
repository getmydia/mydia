//! UUID encoding that matches Ecto's `:binary_id` on-disk format.
//!
//! Phoenix uses `ecto_sqlite3`'s default `:binary_id_type = :string`,
//! which stores UUIDs as 36-character lowercase-hyphenated TEXT on
//! `SQLite` (e.g. `0186fa3d-1c2f-7c4f-9aaa-1234567890ab`). Postgres uses
//! the native `uuid` type. `SeaORM`'s own `Value::Uuid` writes a BLOB to
//! `SQLite` via sqlx-sqlite's default `Encode`, which would corrupt
//! cross-backend reads; the [`UuidText`] wrapper routes the value
//! through `Value::String` instead, with the Postgres cast applied via
//! [`UuidText::into_simple_expr`] at write time. Reads engine-branch in
//! [`TryGetable`] — Postgres reads the native `uuid` and converts to
//! text storage, `SQLite` reads TEXT and parses. The spike empirically
//! established that no single context-free `Value` variant satisfies
//! both engines; the wrapper carries the engine awareness so call
//! sites can stay dialect-agnostic.

use std::fmt;
use std::str::FromStr;

use sea_orm::sea_query::{
    ArrayType, ColumnType, Expr, Nullable, SimpleExpr, Value, ValueType, ValueTypeErr,
};
use sea_orm::{ColIdx, DbBackend, DbErr, QueryResult, TryFromU64, TryGetError, TryGetable};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Newtype wrapper around [`uuid::Uuid`] that encodes as TEXT on `SQLite`
/// and as the native `uuid` type on Postgres.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
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

// ---------- SeaORM (engine-aware via wrapper helpers) ----------
//
// `From<UuidText> for Value` emits `Value::String` universally — the
// dialect-specific cast for Postgres `uuid` columns is applied later by
// [`UuidText::into_simple_expr`] (consumed by the workspace
// `insert_active_model` helper and `Entity::update_many().col_expr`).
// `TryGetable` engine-branches via `QueryResult::try_as_pg_row` so
// Postgres reads decode the native `uuid` column directly while SQLite
// reads parse the Ecto-compatible hyphenated TEXT.

impl From<UuidText> for Value {
    fn from(value: UuidText) -> Self {
        Value::String(Some(value.0.as_hyphenated().to_string()))
    }
}

impl ValueType for UuidText {
    fn try_from(v: Value) -> Result<Self, ValueTypeErr> {
        match v {
            Value::String(Some(s)) => Uuid::parse_str(&s).map(Self).map_err(|_| ValueTypeErr),
            _ => Err(ValueTypeErr),
        }
    }

    fn type_name() -> String {
        "UuidText".to_string()
    }

    fn array_type() -> ArrayType {
        ArrayType::String
    }

    fn column_type() -> ColumnType {
        ColumnType::Uuid
    }
}

impl Nullable for UuidText {
    fn null() -> Value {
        Value::String(None)
    }
}

impl TryGetable for UuidText {
    fn try_get_by<I: ColIdx>(res: &QueryResult, idx: I) -> Result<Self, TryGetError> {
        if res.try_as_pg_row().is_some() {
            <Uuid as TryGetable>::try_get_by(res, idx).map(Self)
        } else {
            let s = <String as TryGetable>::try_get_by(res, idx)?;
            Uuid::parse_str(&s)
                .map(Self)
                .map_err(|e| TryGetError::DbErr(DbErr::Type(format!("invalid UuidText: {e}"))))
        }
    }
}

impl TryFromU64 for UuidText {
    fn try_from_u64(_: u64) -> Result<Self, DbErr> {
        Err(DbErr::ConvertFromU64("UuidText"))
    }
}

impl UuidText {
    /// Emit a `SeaORM` `SimpleExpr` that binds this UUID against either
    /// engine. Use at call sites where the column is wrapper-typed —
    /// `SQLite` gets a plain `Value::String` bind, Postgres gets the
    /// `$N::uuid` cast required to write into a native `uuid` column
    /// from a string parameter.
    ///
    /// This is the one location in landed code permitted to use
    /// `Expr::cust_with_values`; the post-merge verification grep
    /// allow-lists `crates/db/src/types/` for that pattern.
    pub fn into_simple_expr(self, backend: DbBackend) -> SimpleExpr {
        let s = self.0.as_hyphenated().to_string();
        match backend {
            DbBackend::Sqlite => SimpleExpr::Value(Value::String(Some(s))),
            DbBackend::Postgres => Expr::cust_with_values("$1::uuid", vec![Value::String(Some(s))]),
            DbBackend::MySql => {
                unreachable!("mydia-rs is dual-engine SQLite/Postgres only")
            }
            _ => unreachable!(
                "unknown DbBackend variant; mydia-rs is dual-engine SQLite/Postgres only"
            ),
        }
    }
}
