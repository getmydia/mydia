use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct LibraryPathRow {
    pub id: String,
    pub path: String,
    pub library_type: String,
    pub monitored: bool,
    pub scan_interval: Option<i64>,
    pub last_scan_at: Option<String>,
    pub inserted_at: String,
    pub updated_at: String,
}

const LIBRARY_TYPES: &[&str] = &["movies", "series", "mixed"];

const SELECT: &str = "SELECT id, path, library_type, monitored, scan_interval,
                             last_scan_at, inserted_at, updated_at
                      FROM library_paths";

/// Makes the rows match the configured paths exactly: new paths are inserted,
/// existing paths keep their id and their last_scan_at, and paths no longer in
/// the configuration are deleted along with everything they own.
///
/// Deleting cascades to media items and files. That is correct: those rows
/// describe a directory the operator has stopped pointing us at, and nothing
/// inside the media library itself is touched.
pub async fn sync_from_config(
    db: &Db,
    configured: &[(String, String)],
) -> Result<Vec<LibraryPathRow>, DbError> {
    // Validate everything before writing anything, so a typo in the third
    // path does not leave the first two applied.
    for (_, library_type) in configured {
        if !LIBRARY_TYPES.contains(&library_type.as_str()) {
            return Err(DbError::InvalidLibraryType {
                value: library_type.clone(),
            });
        }
    }

    let now = Utc::now().to_rfc3339();

    for (path, library_type) in configured {
        sqlx::query(
            "INSERT INTO library_paths
               (id, path, library_type, monitored, inserted_at, updated_at)
             VALUES (?, ?, ?, 1, ?, ?)
             ON CONFLICT(path) DO UPDATE SET
               library_type = excluded.library_type,
               updated_at   = excluded.updated_at",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(path)
        .bind(library_type)
        .bind(&now)
        .bind(&now)
        .execute(db.pool())
        .await?;
    }

    let keep: Vec<&str> = configured.iter().map(|(p, _)| p.as_str()).collect();

    let sql = if keep.is_empty() {
        "DELETE FROM library_paths".to_string()
    } else {
        // Built by hand because sqlx cannot bind a list to an IN clause.
        let placeholders = vec!["?"; keep.len()].join(", ");
        format!("DELETE FROM library_paths WHERE path NOT IN ({placeholders})")
    };

    let mut delete = sqlx::query(&sql);
    for path in &keep {
        delete = delete.bind(*path);
    }
    delete.execute(db.pool()).await?;

    list(db).await
}

pub async fn list(db: &Db) -> Result<Vec<LibraryPathRow>, DbError> {
    let sql = format!("{SELECT} ORDER BY path");

    Ok(sqlx::query_as::<_, LibraryPathRow>(&sql)
        .fetch_all(db.pool())
        .await?)
}

pub async fn find(db: &Db, id: &str) -> Result<Option<LibraryPathRow>, DbError> {
    let sql = format!("{SELECT} WHERE id = ?");

    Ok(sqlx::query_as::<_, LibraryPathRow>(&sql)
        .bind(id)
        .fetch_optional(db.pool())
        .await?)
}

pub async fn touch_scanned(db: &Db, id: &str) -> Result<(), DbError> {
    let now = Utc::now().to_rfc3339();

    sqlx::query("UPDATE library_paths SET last_scan_at = ?, updated_at = ? WHERE id = ?")
        .bind(&now)
        .bind(&now)
        .bind(id)
        .execute(db.pool())
        .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{find, list, sync_from_config, touch_scanned};
    use crate::pool::connect_temp;

    fn pairs() -> Vec<(String, String)> {
        vec![
            ("/media/movies".to_string(), "movies".to_string()),
            ("/media/tv".to_string(), "series".to_string()),
        ]
    }

    #[tokio::test]
    async fn configured_paths_become_rows() {
        let (db, _g) = connect_temp().await.unwrap();

        let rows = sync_from_config(&db, &pairs()).await.unwrap();

        assert_eq!(rows.len(), 2);
        assert_eq!(list(&db).await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn syncing_twice_does_not_duplicate_or_change_ids() {
        let (db, _g) = connect_temp().await.unwrap();

        let first = sync_from_config(&db, &pairs()).await.unwrap();
        let second = sync_from_config(&db, &pairs()).await.unwrap();

        assert_eq!(second.len(), 2);
        assert_eq!(first[0].id, second[0].id, "ids must be stable across boots");
    }

    #[tokio::test]
    async fn a_path_removed_from_config_is_removed_from_the_database() {
        let (db, _g) = connect_temp().await.unwrap();
        sync_from_config(&db, &pairs()).await.unwrap();

        sync_from_config(&db, &pairs()[..1]).await.unwrap();

        let remaining = list(&db).await.unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].path, "/media/movies");
    }

    #[tokio::test]
    async fn an_empty_configuration_removes_every_path() {
        let (db, _g) = connect_temp().await.unwrap();
        sync_from_config(&db, &pairs()).await.unwrap();

        sync_from_config(&db, &[]).await.unwrap();

        assert!(list(&db).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_unknown_library_type_is_rejected() {
        let (db, _g) = connect_temp().await.unwrap();

        let bad = vec![("/media/x".to_string(), "photos".to_string())];

        assert!(sync_from_config(&db, &bad).await.is_err());
    }

    #[tokio::test]
    async fn a_rejected_type_does_not_partially_apply() {
        let (db, _g) = connect_temp().await.unwrap();

        let mixed = vec![
            ("/media/movies".to_string(), "movies".to_string()),
            ("/media/x".to_string(), "photos".to_string()),
        ];

        assert!(sync_from_config(&db, &mixed).await.is_err());
        assert!(
            list(&db).await.unwrap().is_empty(),
            "validate before writing"
        );
    }

    #[tokio::test]
    async fn touching_records_the_scan_time() {
        let (db, _g) = connect_temp().await.unwrap();
        let rows = sync_from_config(&db, &pairs()).await.unwrap();
        assert!(rows[0].last_scan_at.is_none());

        touch_scanned(&db, &rows[0].id).await.unwrap();

        let after = find(&db, &rows[0].id).await.unwrap().unwrap();
        assert!(after.last_scan_at.is_some());
    }
}
