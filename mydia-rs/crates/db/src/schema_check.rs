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

use sqlx::Row;

use crate::error::DbError;
use crate::pool::Db;

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
pub async fn schema_check(db: &Db) -> Result<SchemaCheckOutcome, DbError> {
    let raw_version = match db {
        Db::Sqlite(pool) => {
            // Dialect-divergent: `sqlite_master` is SQLite-only.
            #[allow(clippy::disallowed_methods)]
            let exists: Option<String> = sqlx::query_scalar(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'",
            )
            .fetch_optional(pool)
            .await?;

            if exists.is_none() {
                tracing::error!(
                    "schema_migrations table missing; this doesn't look like a mydia database"
                );
                return Ok(SchemaCheckOutcome::SchemaMissing);
            }

            // schema_migrations is Phoenix-owned and absent from the macro prepare schema.
            #[allow(clippy::disallowed_methods)]
            let row = sqlx::query("SELECT MAX(version) AS v FROM schema_migrations")
                .fetch_one(pool)
                .await?;
            row.try_get::<Option<i64>, _>("v")?
        }
        Db::Postgres(pool) => {
            // Dialect-divergent: `to_regclass` is Postgres-only.
            #[allow(clippy::disallowed_methods)]
            let exists: Option<String> =
                sqlx::query_scalar("SELECT to_regclass('public.schema_migrations')::text")
                    .fetch_one(pool)
                    .await?;

            if exists.is_none() {
                tracing::error!(
                    "schema_migrations table missing; this doesn't look like a mydia database"
                );
                return Ok(SchemaCheckOutcome::SchemaMissing);
            }

            // schema_migrations is Phoenix-owned and absent from the macro prepare schema.
            #[allow(clippy::disallowed_methods)]
            let row = sqlx::query("SELECT MAX(version) AS v FROM schema_migrations")
                .fetch_one(pool)
                .await?;
            row.try_get::<Option<i64>, _>("v")?
        }
    };

    let Some(version) = raw_version else {
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
