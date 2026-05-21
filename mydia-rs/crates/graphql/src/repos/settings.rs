//! Port of the slice of `Mydia.Settings` the browse + admin resolvers
//! call into.

use mydia_rs_db::Db;
use mydia_rs_models::LibraryPath;

const LIBRARY_PATH_COLUMNS: &str =
    "id, path, type, monitored, scan_interval, last_scan_at, last_scan_status, last_scan_error, \
     from_env, disabled, category_paths, auto_organize, auto_import, write_nfo, auto_rename, \
     quality_profile_id, updated_by_id, inserted_at, updated_at";

/// List all library paths, ordered by `path`. Filters out the
/// `disabled = true` rows the admin marks as unused. Mirrors
/// `Mydia.Settings.list_library_paths/0`.
pub async fn list_library_paths(db: &Db) -> Result<Vec<LibraryPath>, sqlx::Error> {
    let sql = format!(
        "SELECT {LIBRARY_PATH_COLUMNS} FROM library_paths \
         WHERE disabled = $1 ORDER BY path ASC"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, LibraryPath>(&sql)
                .bind(false)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, LibraryPath>(&sql)
                .bind(false)
                .fetch_all(pool)
                .await
        }
    }
}

/// Fetch one library path by UUID.
pub async fn get_library_path(db: &Db, id: &str) -> Result<Option<LibraryPath>, sqlx::Error> {
    let sql = format!("SELECT {LIBRARY_PATH_COLUMNS} FROM library_paths WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, LibraryPath>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, LibraryPath>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}
