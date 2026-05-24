//! UTC datetime encoding matching `ecto_sqlite3`'s default ISO 8601
//! serialization (`2026-05-21T12:34:56Z`) and Postgres `TIMESTAMPTZ`.
//!
//! Two flavors:
//!
//! - [`DateTimeSecs`] -> Ecto `:utc_datetime`. Second precision, RFC3339
//!   with `T` and trailing `Z` on `SQLite` (e.g. `2026-05-21T12:34:56Z`).
//! - [`DateTimeMicros`] -> Ecto `:utc_datetime_usec`. Same format with
//!   `.NNNNNN` microsecond suffix (e.g. `2026-05-21T12:34:56.123456Z`).
//!   Used by `release_blacklist.expires_at`,
//!   `release_blacklist.inserted_at`, and `download.last_progress_at`.
//!
//! sqlx-sqlite's built-in `DateTime<Utc>` encoding produces
//! `"YYYY-MM-DD HH:MM:SS"` (space separator, no `Z`), which Ecto would
//! still parse but mydia-rs would round-trip with subtle drift. Going
//! through TEXT explicitly keeps Phoenix and mydia-rs writes byte-equal.

use chrono::{DateTime, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use sea_orm::sea_query::{
    ArrayType, ColumnType, Expr, Nullable, SimpleExpr, Value, ValueType, ValueTypeErr,
};
use sea_orm::{ColIdx, DbBackend, DbErr, QueryResult, TryGetError, TryGetable};
use serde::{Deserialize, Serialize};
use sqlx::database::Database;
use sqlx::decode::Decode;
use sqlx::encode::{Encode, IsNull};
use sqlx::error::BoxDynError;
use sqlx::{Postgres, Sqlite, Type};

/// Ecto `:utc_datetime` (second precision).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DateTimeSecs(pub DateTime<Utc>);

impl From<DateTime<Utc>> for DateTimeSecs {
    fn from(value: DateTime<Utc>) -> Self {
        Self(value.with_nanosecond_truncated_to_seconds())
    }
}

impl From<DateTimeSecs> for DateTime<Utc> {
    fn from(value: DateTimeSecs) -> Self {
        value.0
    }
}

/// Ecto `:utc_datetime_usec` (microsecond precision).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DateTimeMicros(pub DateTime<Utc>);

impl From<DateTime<Utc>> for DateTimeMicros {
    fn from(value: DateTime<Utc>) -> Self {
        Self(value.with_nanosecond_truncated_to_micros())
    }
}

impl From<DateTimeMicros> for DateTime<Utc> {
    fn from(value: DateTimeMicros) -> Self {
        value.0
    }
}

// ---------- SQLite (TEXT) ----------

impl Type<Sqlite> for DateTimeSecs {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
    fn compatible(ty: &<Sqlite as Database>::TypeInfo) -> bool {
        <String as Type<Sqlite>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Sqlite> for DateTimeSecs {
    fn encode_by_ref(
        &self,
        buf: &mut <Sqlite as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        // SecondsFormat::Secs + use_z=true gives "...Z" not "...+00:00".
        let s = self.0.to_rfc3339_opts(SecondsFormat::Secs, true);
        <String as Encode<'q, Sqlite>>::encode_by_ref(&s, buf)
    }
}

impl<'r> Decode<'r, Sqlite> for DateTimeSecs {
    fn decode(value: <Sqlite as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let s = <String as Decode<'r, Sqlite>>::decode(value)?;
        Ok(Self(parse_ecto_iso8601(&s)?))
    }
}

impl Type<Sqlite> for DateTimeMicros {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
    fn compatible(ty: &<Sqlite as Database>::TypeInfo) -> bool {
        <String as Type<Sqlite>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Sqlite> for DateTimeMicros {
    fn encode_by_ref(
        &self,
        buf: &mut <Sqlite as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        let s = self.0.to_rfc3339_opts(SecondsFormat::Micros, true);
        <String as Encode<'q, Sqlite>>::encode_by_ref(&s, buf)
    }
}

impl<'r> Decode<'r, Sqlite> for DateTimeMicros {
    fn decode(value: <Sqlite as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        let s = <String as Decode<'r, Sqlite>>::decode(value)?;
        Ok(Self(parse_ecto_iso8601(&s)?))
    }
}

// ---------- Postgres (TIMESTAMPTZ) ----------

impl Type<Postgres> for DateTimeSecs {
    fn type_info() -> <Postgres as Database>::TypeInfo {
        <DateTime<Utc> as Type<Postgres>>::type_info()
    }
    fn compatible(ty: &<Postgres as Database>::TypeInfo) -> bool {
        <DateTime<Utc> as Type<Postgres>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Postgres> for DateTimeSecs {
    fn encode_by_ref(
        &self,
        buf: &mut <Postgres as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        <DateTime<Utc> as Encode<'q, Postgres>>::encode_by_ref(&self.0, buf)
    }
}

impl<'r> Decode<'r, Postgres> for DateTimeSecs {
    fn decode(value: <Postgres as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        Ok(Self(<DateTime<Utc> as Decode<'r, Postgres>>::decode(
            value,
        )?))
    }
}

impl Type<Postgres> for DateTimeMicros {
    fn type_info() -> <Postgres as Database>::TypeInfo {
        <DateTime<Utc> as Type<Postgres>>::type_info()
    }
    fn compatible(ty: &<Postgres as Database>::TypeInfo) -> bool {
        <DateTime<Utc> as Type<Postgres>>::compatible(ty)
    }
}

impl<'q> Encode<'q, Postgres> for DateTimeMicros {
    fn encode_by_ref(
        &self,
        buf: &mut <Postgres as Database>::ArgumentBuffer<'q>,
    ) -> Result<IsNull, BoxDynError> {
        <DateTime<Utc> as Encode<'q, Postgres>>::encode_by_ref(&self.0, buf)
    }
}

impl<'r> Decode<'r, Postgres> for DateTimeMicros {
    fn decode(value: <Postgres as Database>::ValueRef<'r>) -> Result<Self, BoxDynError> {
        Ok(Self(<DateTime<Utc> as Decode<'r, Postgres>>::decode(
            value,
        )?))
    }
}

// ---------- SeaORM (engine-aware via wrapper helpers) ----------
//
// Both flavors marshal to `Value::String` (RFC3339 with `T`/`Z` and the
// appropriate sub-second suffix). Writes against Postgres `TIMESTAMPTZ`
// columns route through [`DateTimeSecs::into_simple_expr`] /
// [`DateTimeMicros::into_simple_expr`] which inject the `$N::timestamptz`
// cast; SQLite gets a plain string bind matching Phoenix's Ecto
// `:utc_datetime[_usec]` on-disk form. Reads engine-branch — Postgres
// reads `DateTime<Utc>` natively, SQLite reads the Ecto-ISO8601 TEXT and
// parses with [`parse_ecto_iso8601`].

impl From<DateTimeSecs> for Value {
    fn from(value: DateTimeSecs) -> Self {
        Value::String(Some(value.0.to_rfc3339_opts(SecondsFormat::Secs, true)))
    }
}

impl ValueType for DateTimeSecs {
    fn try_from(v: Value) -> Result<Self, ValueTypeErr> {
        match v {
            Value::String(Some(s)) => parse_ecto_iso8601(&s)
                .map(DateTimeSecs)
                .map_err(|_| ValueTypeErr),
            _ => Err(ValueTypeErr),
        }
    }

    fn type_name() -> String {
        "DateTimeSecs".to_string()
    }

    fn array_type() -> ArrayType {
        ArrayType::String
    }

    fn column_type() -> ColumnType {
        ColumnType::TimestampWithTimeZone
    }
}

impl Nullable for DateTimeSecs {
    fn null() -> Value {
        Value::String(None)
    }
}

impl TryGetable for DateTimeSecs {
    fn try_get_by<I: ColIdx>(res: &QueryResult, idx: I) -> Result<Self, TryGetError> {
        if res.try_as_pg_row().is_some() {
            <DateTime<Utc> as TryGetable>::try_get_by(res, idx).map(Self)
        } else {
            let s = <String as TryGetable>::try_get_by(res, idx)?;
            parse_ecto_iso8601(&s)
                .map(Self)
                .map_err(|e| TryGetError::DbErr(DbErr::Type(format!("invalid DateTimeSecs: {e}"))))
        }
    }
}

impl DateTimeSecs {
    /// `SeaORM` `SimpleExpr` that binds this timestamp against either
    /// engine, applying the `$N::timestamptz` cast on Postgres where
    /// the wrapper's string form would otherwise fail to coerce.
    pub fn into_simple_expr(self, backend: DbBackend) -> SimpleExpr {
        let s = self.0.to_rfc3339_opts(SecondsFormat::Secs, true);
        timestamptz_simple_expr(backend, s)
    }
}

impl From<DateTimeMicros> for Value {
    fn from(value: DateTimeMicros) -> Self {
        Value::String(Some(value.0.to_rfc3339_opts(SecondsFormat::Micros, true)))
    }
}

impl ValueType for DateTimeMicros {
    fn try_from(v: Value) -> Result<Self, ValueTypeErr> {
        match v {
            Value::String(Some(s)) => parse_ecto_iso8601(&s)
                .map(DateTimeMicros)
                .map_err(|_| ValueTypeErr),
            _ => Err(ValueTypeErr),
        }
    }

    fn type_name() -> String {
        "DateTimeMicros".to_string()
    }

    fn array_type() -> ArrayType {
        ArrayType::String
    }

    fn column_type() -> ColumnType {
        ColumnType::TimestampWithTimeZone
    }
}

impl Nullable for DateTimeMicros {
    fn null() -> Value {
        Value::String(None)
    }
}

impl TryGetable for DateTimeMicros {
    fn try_get_by<I: ColIdx>(res: &QueryResult, idx: I) -> Result<Self, TryGetError> {
        if res.try_as_pg_row().is_some() {
            <DateTime<Utc> as TryGetable>::try_get_by(res, idx).map(Self)
        } else {
            let s = <String as TryGetable>::try_get_by(res, idx)?;
            parse_ecto_iso8601(&s).map(Self).map_err(|e| {
                TryGetError::DbErr(DbErr::Type(format!("invalid DateTimeMicros: {e}")))
            })
        }
    }
}

impl DateTimeMicros {
    /// `SeaORM` `SimpleExpr` that binds this microsecond-precision
    /// timestamp against either engine. Same cast handling as
    /// [`DateTimeSecs::into_simple_expr`].
    pub fn into_simple_expr(self, backend: DbBackend) -> SimpleExpr {
        let s = self.0.to_rfc3339_opts(SecondsFormat::Micros, true);
        timestamptz_simple_expr(backend, s)
    }
}

fn timestamptz_simple_expr(backend: DbBackend, value: String) -> SimpleExpr {
    match backend {
        DbBackend::Sqlite => SimpleExpr::Value(Value::String(Some(value))),
        DbBackend::Postgres => {
            Expr::cust_with_values("$1::timestamptz", vec![Value::String(Some(value))])
        }
        DbBackend::MySql => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
        _ => {
            unreachable!("unknown DbBackend variant; mydia-rs is dual-engine SQLite/Postgres only")
        }
    }
}

/// Parse Ecto's ISO 8601 forms. Accepts the canonical form mydia writes
/// (`2026-05-21T12:34:56Z`, with or without microsecond suffix) and the
/// legacy `"YYYY-MM-DD HH:MM:SS"` form so we can read rows older
/// Phoenix versions might have written before the `:iso8601` default
/// became uniform.
fn parse_ecto_iso8601(s: &str) -> Result<DateTime<Utc>, chrono::ParseError> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.with_timezone(&Utc));
    }
    // Legacy SQLite "naive" format (no timezone): treat as UTC.
    let naive = NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S")?;
    Ok(Utc.from_utc_datetime(&naive))
}

/// Small helper trait kept private so users don't accidentally truncate
/// nanoseconds on a chrono `DateTime<Utc>` directly. Used by the
/// `From<DateTime<Utc>>` impls above so constructing `DateTimeSecs::from(...)`
/// always yields the on-disk-equivalent value.
trait TruncatedNanos {
    fn with_nanosecond_truncated_to_seconds(self) -> Self;
    fn with_nanosecond_truncated_to_micros(self) -> Self;
}

impl TruncatedNanos for DateTime<Utc> {
    fn with_nanosecond_truncated_to_seconds(self) -> Self {
        self.with_nanosecond(0).unwrap_or(self)
    }
    fn with_nanosecond_truncated_to_micros(self) -> Self {
        let nanos = self.timestamp_subsec_micros() * 1000;
        self.with_nanosecond(nanos).unwrap_or(self)
    }
}

// Re-export chrono's setter via the trait above without importing
// chrono::Timelike at the module top (keeps the public surface clean).
use chrono::Timelike as _;
