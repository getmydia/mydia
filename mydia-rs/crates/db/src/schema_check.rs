//! Boot-time `schema_migrations` probe.
//!
//! mydia-rs reads but never writes `schema_migrations` (Phoenix owns
//! every migration). At startup we compare the highest version in the DB
//! against [`MAX_KNOWN_MIGRATION`], a constant embedded at build time:
//!
//! - DB version > `MAX_KNOWN_MIGRATION` -> Phoenix has migrated past
//!   this binary. We log a WARN and continue with degraded confidence;
//!   `SELECT *` is forbidden in mydia-rs so additive migrations are
//!   tolerable. The operator's correct response is to pull a newer
//!   mydia-rs image when convenient.
//! - DB version < `MAX_KNOWN_MIGRATION` -> this mydia-rs is newer than
//!   the Phoenix release the operator's DB was migrated against. We log
//!   an ERROR and surface a `SchemaTooOld` result so the caller can
//!   exit non-zero with a clear "boot Phoenix to migrate first" message.
//! - DB version == `MAX_KNOWN_MIGRATION` -> exact match.
//!
//! Missing `schema_migrations` table -> this doesn't look like a mydia
//! database. Surface as `SchemaMissing`.
//!
//! Implementation note: the probe lives in `mydia-rs-db` rather than
//! `mydia-rs-entities` (where the `schema_migrations` entity itself
//! sits) because `entities` already depends on `db` for the wrapper
//! types. Adding the reverse direction would create a cycle, so this
//! file falls back to raw `Statement::from_string` for the two queries
//! it needs — `match db.get_database_backend()` covers the dialect
//! divergence on the existence check, and the version-max query is
//! identical SQL on both engines.

use sea_orm::{ConnectionTrait, DatabaseConnection, DbBackend, Statement};

use crate::error::DbError;

/// Highest Phoenix migration version this build of mydia-rs has been
/// tested against. Bump whenever a new migration is pulled into the
/// reference snapshot.
///
/// Migrations live under `priv/repo/migrations/` and follow Ecto's
/// `YYYYMMDDHHMMSS_*.exs` naming, with the prefix being the version.
// The Y_M_D_H_M_S grouping mirrors the migration filename shape, which
// reads clearer than the pedantic-preferred groups-of-three.
#[allow(clippy::inconsistent_digit_grouping)]
pub const MAX_KNOWN_MIGRATION: i64 = 2026_05_16_15_27_31;

/// Result of [`schema_check`]. The caller decides whether to exit
/// non-zero based on the variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchemaCheckOutcome {
    /// DB version matches `MAX_KNOWN_MIGRATION` exactly.
    Match { version: i64 },
    /// Phoenix has migrated past this binary. Boot continues.
    SchemaAhead { version: i64 },
    /// DB is older than this binary expects. Caller should refuse to start.
    SchemaTooOld { version: i64 },
    /// `schema_migrations` table doesn't exist. Not a mydia DB; caller
    /// should refuse to start.
    SchemaMissing,
}

/// Probe the schema version. Returns the outcome and logs at the
/// appropriate tracing level for that case.
pub async fn schema_check(db: &DatabaseConnection) -> Result<SchemaCheckOutcome, DbError> {
    let backend = db.get_database_backend();

    // Existence check: SQLite uses sqlite_master, Postgres uses
    // to_regclass. The output column name differs, so probe by row
    // presence rather than by reading the column value.
    let exists_sql = match backend {
        DbBackend::Sqlite => {
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'"
        }
        DbBackend::Postgres => {
            "SELECT to_regclass('public.schema_migrations')::text AS name WHERE to_regclass('public.schema_migrations') IS NOT NULL"
        }
        DbBackend::MySql => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
        _ => unreachable!(
            "unknown DbBackend variant; mydia-rs is dual-engine SQLite/Postgres only"
        ),
    };
    let exists = db
        .query_one_raw(Statement::from_string(backend, exists_sql.to_string()))
        .await?
        .is_some();
    if !exists {
        tracing::error!("schema_migrations table missing; this doesn't look like a mydia database");
        return Ok(SchemaCheckOutcome::SchemaMissing);
    }

    // Version-max query: identical SQL on both engines, identical
    // result-column name, dialect-portable through Statement::from_string.
    let row = db
        .query_one_raw(Statement::from_string(
            backend,
            "SELECT MAX(version) AS v FROM schema_migrations".to_string(),
        ))
        .await?;
    let Some(row) = row else {
        tracing::error!("schema_migrations exists but max(version) returned no rows");
        return Ok(SchemaCheckOutcome::SchemaMissing);
    };
    let version: Option<i64> = row.try_get_by("v")?;
    let Some(version) = version else {
        tracing::error!("schema_migrations exists but is empty");
        return Ok(SchemaCheckOutcome::SchemaMissing);
    };

    match version.cmp(&MAX_KNOWN_MIGRATION) {
        std::cmp::Ordering::Equal => {
            tracing::info!(version, "schema_migrations matches expected version");
            Ok(SchemaCheckOutcome::Match { version })
        }
        std::cmp::Ordering::Greater => {
            tracing::warn!(
                version,
                expected = MAX_KNOWN_MIGRATION,
                "Phoenix has migrated past this mydia-rs build; some queries may surprise. Pull a newer mydia-rs image when convenient.",
            );
            Ok(SchemaCheckOutcome::SchemaAhead { version })
        }
        std::cmp::Ordering::Less => {
            tracing::error!(
                version,
                expected = MAX_KNOWN_MIGRATION,
                "DB is older than this mydia-rs build expects; boot Phoenix once to run pending migrations, then try again.",
            );
            Ok(SchemaCheckOutcome::SchemaTooOld { version })
        }
    }
}
