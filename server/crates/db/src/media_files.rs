use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct MediaFileRow {
    pub id: String,
    pub media_item_id: Option<String>,
    pub episode_id: Option<String>,
    pub path: String,
    /// Bytes. i64 rather than i32 because a 4 GB film does not fit in 32 bits,
    /// and the contract's Int is Absinthe's non-spec-compliant 2^53 Int.
    pub size: Option<i64>,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    pub bitrate: Option<i64>,
    pub duration_seconds: Option<f64>,
    pub container: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub subtitle_tracks: Option<String>,
    pub mtime: String,
    pub scanned_at: String,
}

/// A file belongs to a movie or to an episode. The type makes the third
/// possibility unrepresentable, which is the same invariant the table's CHECK
/// constraint enforces.
#[derive(Debug, Clone)]
pub enum Owner {
    Item(String),
    Episode(String),
}

#[derive(Debug, Clone)]
pub struct NewMediaFile {
    pub owner: Owner,
    pub path: String,
    pub size: Option<i64>,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    pub bitrate: Option<i64>,
    pub duration_seconds: Option<f64>,
    pub container: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub subtitle_tracks: Option<String>,
    pub mtime: String,
}

const SELECT: &str = "SELECT id, media_item_id, episode_id, path, size, resolution, codec,
                             audio_codec, hdr_format, bitrate, duration_seconds, container,
                             width, height, subtitle_tracks, mtime, scanned_at
                      FROM media_files";

/// Stores a file, keyed on its path. A file whose parse result changed moves
/// to its new owner rather than leaving a stale row behind, which is why both
/// owner columns are written on conflict.
pub async fn upsert(db: &Db, new: NewMediaFile) -> Result<MediaFileRow, DbError> {
    let now = Utc::now().to_rfc3339();

    let (media_item_id, episode_id) = match &new.owner {
        Owner::Item(id) => (Some(id.as_str()), None),
        Owner::Episode(id) => (None, Some(id.as_str())),
    };

    sqlx::query(
        "INSERT INTO media_files
           (id, media_item_id, episode_id, path, size, resolution, codec, audio_codec,
            hdr_format, bitrate, duration_seconds, container, width, height,
            subtitle_tracks, mtime, scanned_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(path) DO UPDATE SET
           media_item_id    = excluded.media_item_id,
           episode_id       = excluded.episode_id,
           size             = excluded.size,
           resolution       = excluded.resolution,
           codec            = excluded.codec,
           audio_codec      = excluded.audio_codec,
           hdr_format       = excluded.hdr_format,
           bitrate          = excluded.bitrate,
           duration_seconds = excluded.duration_seconds,
           container        = excluded.container,
           width            = excluded.width,
           height           = excluded.height,
           subtitle_tracks  = excluded.subtitle_tracks,
           mtime            = excluded.mtime,
           scanned_at       = excluded.scanned_at",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(media_item_id)
    .bind(episode_id)
    .bind(&new.path)
    .bind(new.size)
    .bind(&new.resolution)
    .bind(&new.codec)
    .bind(&new.audio_codec)
    .bind(&new.hdr_format)
    .bind(new.bitrate)
    .bind(new.duration_seconds)
    .bind(&new.container)
    .bind(new.width)
    .bind(new.height)
    .bind(&new.subtitle_tracks)
    .bind(&new.mtime)
    .bind(&now)
    .execute(db.pool())
    .await?;

    Ok(find_by_path(db, &new.path)
        .await?
        .expect("the row was just written"))
}

pub async fn find_by_path(db: &Db, path: &str) -> Result<Option<MediaFileRow>, DbError> {
    let sql = format!("{SELECT} WHERE path = ?");

    Ok(sqlx::query_as::<_, MediaFileRow>(&sql)
        .bind(path)
        .fetch_optional(db.pool())
        .await?)
}

pub async fn list_for_item(db: &Db, media_item_id: &str) -> Result<Vec<MediaFileRow>, DbError> {
    let sql = format!("{SELECT} WHERE media_item_id = ? ORDER BY path");

    Ok(sqlx::query_as::<_, MediaFileRow>(&sql)
        .bind(media_item_id)
        .fetch_all(db.pool())
        .await?)
}

pub async fn list_for_episode(db: &Db, episode_id: &str) -> Result<Vec<MediaFileRow>, DbError> {
    let sql = format!("{SELECT} WHERE episode_id = ? ORDER BY path");

    Ok(sqlx::query_as::<_, MediaFileRow>(&sql)
        .bind(episode_id)
        .fetch_all(db.pool())
        .await?)
}

/// Removes rows for files this library no longer contains. Rows only: nothing
/// on disk is touched, because Mydia Server has no delete capability.
///
/// Keep-lists are staged through a temp table so libraries larger than
/// SQLite's bound-parameter limit (commonly 999) still prune correctly.
pub async fn prune_outside(
    db: &Db,
    library_path_id: &str,
    keep: &[String],
) -> Result<u64, DbError> {
    // A file belongs to this library through its item, directly for a movie
    // and through the show for an episode.
    let scope = "(media_item_id IN (SELECT id FROM media_items WHERE library_path_id = ?)
                  OR episode_id IN (SELECT e.id FROM episodes e
                                    JOIN media_items i ON i.id = e.show_id
                                    WHERE i.library_path_id = ?))";

    if keep.is_empty() {
        let removed = sqlx::query(&format!("DELETE FROM media_files WHERE {scope}"))
            .bind(library_path_id)
            .bind(library_path_id)
            .execute(db.pool())
            .await?
            .rows_affected();
        return Ok(removed);
    }

    // TEMP tables are connection-local, so the whole prune must share one
    // connection via a transaction.
    let mut tx = db.pool().begin().await?;

    sqlx::query(
        "CREATE TEMP TABLE IF NOT EXISTS media_files_prune_keep (
            path TEXT PRIMARY KEY NOT NULL
        )",
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query("DELETE FROM media_files_prune_keep")
        .execute(&mut *tx)
        .await?;

    // Stay well under SQLite's default bind-parameter limit per statement.
    const CHUNK: usize = 400;
    for chunk in keep.chunks(CHUNK) {
        let placeholders = vec!["(?)"; chunk.len()].join(", ");
        let sql =
            format!("INSERT OR IGNORE INTO media_files_prune_keep (path) VALUES {placeholders}");
        let mut query = sqlx::query(&sql);
        for path in chunk {
            query = query.bind(path);
        }
        query.execute(&mut *tx).await?;
    }

    let removed = sqlx::query(&format!(
        "DELETE FROM media_files
         WHERE {scope}
           AND path NOT IN (SELECT path FROM media_files_prune_keep)"
    ))
    .bind(library_path_id)
    .bind(library_path_id)
    .execute(&mut *tx)
    .await?
    .rows_affected();

    sqlx::query("DELETE FROM media_files_prune_keep")
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(removed)
}

/// Removes items and episodes that no longer have any file.
///
/// Run after pruning files. An item with no files would otherwise linger and,
/// while `movies` and `tvShows` filter it out, `node` and `movie(id:)` would
/// still resolve it.
pub async fn prune_empty_items(db: &Db, library_path_id: &str) -> Result<u64, DbError> {
    sqlx::query(
        "DELETE FROM episodes
         WHERE show_id IN (SELECT id FROM media_items WHERE library_path_id = ?)
           AND id NOT IN (SELECT episode_id FROM media_files WHERE episode_id IS NOT NULL)",
    )
    .bind(library_path_id)
    .execute(db.pool())
    .await?;

    let removed = sqlx::query(
        "DELETE FROM media_items
         WHERE library_path_id = ?
           AND id NOT IN (SELECT media_item_id FROM media_files WHERE media_item_id IS NOT NULL)
           AND id NOT IN (SELECT show_id FROM episodes)",
    )
    .bind(library_path_id)
    .execute(db.pool())
    .await?
    .rows_affected();

    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::{
        find_by_path, list_for_episode, list_for_item, prune_empty_items, prune_outside, upsert,
        NewMediaFile, Owner,
    };
    use crate::episodes::{upsert as upsert_episode, NewEpisode};
    use crate::library_paths::sync_from_config;
    use crate::media_items::{upsert as upsert_item, NewMediaItem};
    use crate::pool::connect_temp;
    use crate::Db;

    async fn library(db: &Db) -> String {
        sync_from_config(db, &[("/media".to_string(), "mixed".to_string())])
            .await
            .unwrap()[0]
            .id
            .clone()
    }

    async fn movie(db: &Db, library_path_id: &str, title: &str) -> String {
        upsert_item(
            db,
            NewMediaItem {
                library_path_id: library_path_id.to_string(),
                media_type: "movie".to_string(),
                title: title.to_string(),
                identity_key: title.to_lowercase().replace(' ', ""),
                year: Some(2020),
            },
        )
        .await
        .unwrap()
        .id
    }

    fn file(owner: Owner, path: &str) -> NewMediaFile {
        NewMediaFile {
            owner,
            path: path.to_string(),
            size: Some(8_000_000_000),
            resolution: Some("2160p".to_string()),
            codec: Some("HEVC (Main 10)".to_string()),
            audio_codec: Some("TrueHD 7.1".to_string()),
            hdr_format: Some("Dolby Vision".to_string()),
            bitrate: Some(48_000_000),
            duration_seconds: Some(7200.0),
            container: Some("matroska,webm".to_string()),
            width: Some(3840),
            height: Some(2160),
            subtitle_tracks: Some("[]".to_string()),
            mtime: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    #[tokio::test]
    async fn a_movie_file_is_stored_and_listed() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();

        let listed = list_for_item(&db, &item).await.unwrap();

        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].resolution.as_deref(), Some("2160p"));
    }

    #[tokio::test]
    async fn a_size_above_two_gigabytes_round_trips() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();

        let listed = list_for_item(&db, &item).await.unwrap();

        // 8 GB does not fit in an i32. If this fails, the column or the row
        // struct narrowed somewhere.
        assert_eq!(listed[0].size, Some(8_000_000_000));
    }

    #[tokio::test]
    async fn rescanning_a_file_updates_it_rather_than_duplicating() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        let first = upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();

        let mut again = file(Owner::Item(item.clone()), "/media/a.mkv");
        again.resolution = Some("1080p".to_string());
        let second = upsert(&db, again).await.unwrap();

        assert_eq!(first.id, second.id);
        assert_eq!(second.resolution.as_deref(), Some("1080p"));
        assert_eq!(list_for_item(&db, &item).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_file_can_move_between_owners() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let first_item = movie(&db, &lp, "Wrong Match").await;
        let second_item = movie(&db, &lp, "Right Match").await;

        upsert(&db, file(Owner::Item(first_item.clone()), "/media/a.mkv"))
            .await
            .unwrap();
        upsert(&db, file(Owner::Item(second_item.clone()), "/media/a.mkv"))
            .await
            .unwrap();

        assert!(list_for_item(&db, &first_item).await.unwrap().is_empty());
        assert_eq!(list_for_item(&db, &second_item).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn an_episode_file_is_stored_and_listed() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let show = upsert_item(
            &db,
            NewMediaItem {
                library_path_id: lp,
                media_type: "tv_show".to_string(),
                title: "Show".to_string(),
                identity_key: "show".to_string(),
                year: None,
            },
        )
        .await
        .unwrap()
        .id;

        let episode = upsert_episode(
            &db,
            NewEpisode {
                show_id: show,
                season_number: 1,
                episode_number: 1,
            },
        )
        .await
        .unwrap()
        .id;

        upsert(&db, file(Owner::Episode(episode.clone()), "/media/e.mkv"))
            .await
            .unwrap();

        assert_eq!(list_for_episode(&db, &episode).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn pruning_removes_rows_for_files_that_are_gone() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();
        upsert(&db, file(Owner::Item(item.clone()), "/media/b.mkv"))
            .await
            .unwrap();

        let removed = prune_outside(&db, &lp, &["/media/a.mkv".to_string()])
            .await
            .unwrap();

        assert_eq!(removed, 1);
        assert!(find_by_path(&db, "/media/b.mkv").await.unwrap().is_none());
        assert!(find_by_path(&db, "/media/a.mkv").await.unwrap().is_some());
    }

    #[tokio::test]
    async fn pruning_survives_keep_lists_larger_than_sqlite_bind_limit() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        // One more than SQLite's common 999 bind-parameter limit, plus an
        // orphan that must still be removed.
        let mut keep = Vec::with_capacity(1_000);
        for i in 0..1_000 {
            let path = format!("/media/keep-{i}.mkv");
            upsert(&db, file(Owner::Item(item.clone()), &path))
                .await
                .unwrap();
            keep.push(path);
        }
        upsert(&db, file(Owner::Item(item.clone()), "/media/orphan.mkv"))
            .await
            .unwrap();

        let removed = prune_outside(&db, &lp, &keep).await.unwrap();

        assert_eq!(removed, 1);
        assert!(find_by_path(&db, "/media/orphan.mkv")
            .await
            .unwrap()
            .is_none());
        assert!(find_by_path(&db, &keep[0]).await.unwrap().is_some());
        assert!(find_by_path(&db, keep.last().unwrap())
            .await
            .unwrap()
            .is_some());
    }

    #[tokio::test]
    async fn pruning_nothing_kept_removes_every_file_in_that_library() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();

        assert_eq!(prune_outside(&db, &lp, &[]).await.unwrap(), 1);
    }

    #[tokio::test]
    async fn items_left_with_no_files_are_removed() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let item = movie(&db, &lp, "The Movie").await;

        upsert(&db, file(Owner::Item(item.clone()), "/media/a.mkv"))
            .await
            .unwrap();
        prune_outside(&db, &lp, &[]).await.unwrap();

        let removed = prune_empty_items(&db, &lp).await.unwrap();

        assert_eq!(removed, 1);
        assert!(crate::media_items::find(&db, &item)
            .await
            .unwrap()
            .is_none());
    }
}
