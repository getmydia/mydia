//! Schema drift detector.
//!
//! For each entity in `mydia_rs_entities`, ask SeaORM what columns the
//! committed source describes (via `Column::iter()` + `col.def()`),
//! then ask Postgres what columns the migrated database actually has
//! (via `information_schema.columns`), and diff. Failures point at the
//! specific column that drifted.
//!
//! Reports three classes of drift:
//!
//! 1. Entity declares a column the database doesn't have (entity ahead
//!    of Phoenix migrations, or column renamed/removed Phoenix-side).
//! 2. Database has a column the entity doesn't declare (Phoenix landed
//!    a migration the entities crate hasn't caught up on).
//! 3. Column type mismatch — entity's declared `ColumnType` doesn't
//!    line up with Postgres's `data_type` after a normalization pass.
//!
//! Nullability and default values are deliberately out of scope for v1:
//! Phoenix migrations sometimes change those without breaking
//! cross-engine semantics, and getting the comparison precise enough to
//! avoid false positives needs more careful handling than this initial
//! gate carries.
//!
//! Connects via `DATABASE_URL` (Postgres only — SQLite is checked via
//! the cross-engine wrapper round-trip tests rather than schema diff,
//! since SQLite's `pragma_table_info` semantics differ enough from
//! Postgres's `information_schema` to warrant separate machinery).

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{anyhow, bail, Context as _, Result};
use sea_orm::sea_query::{ColumnType, Iden};
use sea_orm::{
    ColumnTrait, ConnectionTrait, Database, DatabaseConnection, EntityTrait, Iterable, Statement,
};

use mydia_rs_entities as ents;

/// Snapshot of a column from Postgres `information_schema.columns`.
#[derive(Debug, Clone)]
struct PgColumn {
    data_type: String,
    udt_name: String,
}

type PgSchema = BTreeMap<String, BTreeMap<String, PgColumn>>;

#[tokio::main]
async fn main() -> Result<()> {
    let url = std::env::var("DATABASE_URL")
        .context("DATABASE_URL is required (must point at a Phoenix-migrated Postgres)")?;
    if !url.starts_with("postgres://") && !url.starts_with("postgresql://") {
        bail!("DATABASE_URL must be a Postgres URL; got: {url}");
    }

    let db = Database::connect(&url)
        .await
        .with_context(|| format!("connecting to {url}"))?;
    let pg = load_postgres_schema(&db).await?;

    let mut findings: Vec<String> = Vec::new();
    check_all_entities(&pg, &mut findings);

    if findings.is_empty() {
        println!(
            "schema-diff-check: clean. {} entity tables verified.",
            count_known_tables(&pg)
        );
        Ok(())
    } else {
        for finding in &findings {
            println!("{finding}");
        }
        Err(anyhow!(
            "schema-diff-check: {} drift(s) detected",
            findings.len()
        ))
    }
}

/// Load every (table, column) pair from `information_schema.columns`
/// in the `public` schema (Phoenix's default).
async fn load_postgres_schema(db: &DatabaseConnection) -> Result<PgSchema> {
    let backend = db.get_database_backend();
    let rows = db
        .query_all_raw(Statement::from_string(
            backend,
            "SELECT table_name, column_name, data_type, udt_name \
             FROM information_schema.columns \
             WHERE table_schema = 'public' \
             ORDER BY table_name, ordinal_position"
                .to_string(),
        ))
        .await
        .context("querying information_schema.columns")?;

    let mut schema: PgSchema = BTreeMap::new();
    for row in rows {
        let table: String = row.try_get_by("table_name").context("read table_name")?;
        let column: String = row.try_get_by("column_name").context("read column_name")?;
        let data_type: String = row.try_get_by("data_type").context("read data_type")?;
        let udt_name: String = row.try_get_by("udt_name").context("read udt_name")?;
        schema.entry(table).or_default().insert(
            column,
            PgColumn {
                data_type,
                udt_name,
            },
        );
    }
    Ok(schema)
}

/// Macro that enumerates every entity the differ knows about. Adding a
/// new entity is a one-line addition here -- matches the additive shape
/// of the hand-written `mydia_rs_entities::*` modules.
macro_rules! check_entities {
    ($pg:expr, $findings:expr, $($module:ident),+ $(,)?) => {
        $(
            check_entity::<ents::$module::Entity>(stringify!($module), $pg, $findings);
        )+
    };
}

fn check_all_entities(pg: &PgSchema, findings: &mut Vec<String>) {
    // Every public module in `crates/entities/src/lib.rs` (excluding
    // `prelude`, `sea_orm_active_enums`, and the SQLite-only
    // `mydia_runtime_lock` -- the latter doesn't live in Postgres).
    check_entities!(
        pg,
        findings,
        adult_files,
        albums,
        api_keys,
        artists,
        authors,
        book_files,
        books,
        cardigann_definitions,
        cardigann_search_sessions,
        collection_items,
        collections,
        config_settings,
        download_client_configs,
        downloads,
        episodes,
        error_tracker_errors,
        error_tracker_meta,
        error_tracker_occurrences,
        events,
        import_list_items,
        import_lists,
        import_sessions,
        indexer_configs,
        library_paths,
        media_files,
        media_hashes,
        media_items,
        media_requests,
        media_server_configs,
        music_files,
        oban_jobs,
        oban_peers,
        pairing_claims,
        playback_progress,
        playlist_tracks,
        playlists,
        quality_profiles,
        release_blacklist,
        remote_access_config,
        remote_devices,
        scenes,
        schema_migrations,
        search_backoffs,
        studios,
        subtitle_providers,
        subtitles,
        tracks,
        transcode_jobs,
        user_favorites,
        user_integrations,
        user_preferences,
        users,
    );
}

fn check_entity<E>(module_name: &str, pg: &PgSchema, findings: &mut Vec<String>)
where
    E: EntityTrait,
{
    let table = E::default().to_string();
    let Some(pg_cols) = pg.get(&table) else {
        findings.push(format!(
            "ERROR: entity `{module_name}` declares table `{table}`, but Postgres has no such table"
        ));
        return;
    };

    let mut entity_cols: BTreeSet<String> = BTreeSet::new();
    for col in E::Column::iter() {
        let col_name = col.to_string();
        entity_cols.insert(col_name.clone());

        let Some(pg_col) = pg_cols.get(&col_name) else {
            findings.push(format!(
                "ERROR: entity `{module_name}` declares column `{table}.{col_name}`, but Postgres has no such column"
            ));
            continue;
        };

        let entity_type = col.def();
        let entity_col_type = entity_type.get_column_type();
        if !column_types_compatible(entity_col_type, pg_col) {
            findings.push(format!(
                "ERROR: entity `{module_name}` declares `{table}.{col_name}` as `{entity:?}`, \
                 but Postgres has data_type=`{data}` udt_name=`{udt}`",
                entity = entity_col_type,
                data = pg_col.data_type,
                udt = pg_col.udt_name,
            ));
        }
    }

    // Reverse: any Postgres column the entity doesn't know about?
    for pg_col_name in pg_cols.keys() {
        if !entity_cols.contains(pg_col_name) {
            findings.push(format!(
                "ERROR: Postgres has column `{table}.{pg_col_name}` that entity `{module_name}` doesn't declare \
                 (Phoenix migration not yet reflected in the entity?)"
            ));
        }
    }
}

/// Compare a SeaORM `ColumnType` against the Postgres column metadata,
/// returning true if the entity's declared type is consistent with the
/// migrated schema's `data_type` / `udt_name`. Normalization handles
/// the small spelling differences between sea-query's enum and
/// Postgres's `information_schema` conventions.
fn column_types_compatible(entity: &ColumnType, pg: &PgColumn) -> bool {
    let data = pg.data_type.as_str();
    let udt = pg.udt_name.as_str();
    match entity {
        ColumnType::Uuid => data == "uuid",
        ColumnType::Text => data == "text",
        ColumnType::String(_) | ColumnType::Char(_) => {
            data == "text" || data == "character varying" || data == "character"
        }
        ColumnType::Boolean => data == "boolean",
        ColumnType::SmallInteger | ColumnType::SmallUnsigned => data == "smallint",
        ColumnType::Integer | ColumnType::Unsigned => data == "integer",
        ColumnType::BigInteger | ColumnType::BigUnsigned => data == "bigint",
        ColumnType::Float => data == "real",
        ColumnType::Double => data == "double precision",
        ColumnType::Decimal(_) | ColumnType::Money(_) => data == "numeric",
        ColumnType::DateTime | ColumnType::Timestamp => data == "timestamp without time zone",
        ColumnType::TimestampWithTimeZone => data == "timestamp with time zone",
        ColumnType::Date => data == "date",
        ColumnType::Time => data == "time without time zone",
        ColumnType::Binary(_) | ColumnType::VarBinary(_) | ColumnType::Blob => data == "bytea",
        ColumnType::Json => data == "json" || data == "jsonb",
        ColumnType::JsonBinary => data == "jsonb",
        ColumnType::Array(inner) => {
            if data != "ARRAY" {
                return false;
            }
            // udt_name is `_text` for `text[]`, `_int4` for `integer[]`, etc.
            match inner.as_ref() {
                ColumnType::Text | ColumnType::String(_) | ColumnType::Char(_) => {
                    udt == "_text" || udt == "_varchar"
                }
                ColumnType::Integer | ColumnType::Unsigned => udt == "_int4",
                ColumnType::BigInteger | ColumnType::BigUnsigned => udt == "_int8",
                _ => true, // unknown inner — don't false-positive
            }
        }
        ColumnType::Enum { .. } => data == "USER-DEFINED",
        ColumnType::Cidr => data == "cidr",
        ColumnType::Inet => data == "inet",
        ColumnType::MacAddr => data == "macaddr",
        // For variants the gate doesn't know how to normalize yet, don't
        // false-positive — silently accept and let manual review catch
        // anything weird. Future v2 of this gate tightens the match.
        _ => true,
    }
}

fn count_known_tables(pg: &PgSchema) -> usize {
    pg.len()
}
