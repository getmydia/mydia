use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct MediaItemRow {
    pub id: String,
    pub library_path_id: String,
    pub media_type: String,
    pub title: String,
    pub identity_key: String,
    pub original_title: Option<String>,
    pub year: Option<i64>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub overview: Option<String>,
    pub runtime: Option<i64>,
    pub content_rating: Option<String>,
    pub rating: Option<f64>,
    pub status: Option<String>,
    pub genres: Option<String>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub thumbnail_url: Option<String>,
    pub metadata_source: Option<String>,
    pub added_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct NewMediaItem {
    pub library_path_id: String,
    pub media_type: String,
    pub title: String,
    pub identity_key: String,
    pub year: Option<i64>,
}

pub(crate) const SELECT: &str = "SELECT id, library_path_id, media_type, title, identity_key,
                                        original_title, year, tmdb_id, tvdb_id, imdb_id,
                                        overview, runtime, content_rating, rating, status,
                                        genres, poster_url, backdrop_url, thumbnail_url,
                                        metadata_source, added_at, updated_at
                                 FROM media_items";

/// Creates the item or returns the one already standing for this identity.
///
/// `added_at` is preserved on conflict: it means "when this library first
/// contained this item", which is what the player's recently-added rail will
/// sort on in Slice 4. The title is refreshed, since a rename on disk should
/// show up.
pub async fn upsert(db: &Db, new: NewMediaItem) -> Result<MediaItemRow, DbError> {
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO media_items
           (id, library_path_id, media_type, title, identity_key, year, added_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (library_path_id, media_type, identity_key, COALESCE(year, -1))
         DO UPDATE SET
           title      = excluded.title,
           updated_at = excluded.updated_at",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(&new.library_path_id)
    .bind(&new.media_type)
    .bind(&new.title)
    .bind(&new.identity_key)
    .bind(new.year)
    .bind(&now)
    .bind(&now)
    .execute(db.pool())
    .await?;

    let sql = format!(
        "{SELECT} WHERE library_path_id = ? AND media_type = ?
                    AND identity_key = ? AND COALESCE(year, -1) = COALESCE(?, -1)"
    );

    Ok(sqlx::query_as::<_, MediaItemRow>(&sql)
        .bind(&new.library_path_id)
        .bind(&new.media_type)
        .bind(&new.identity_key)
        .bind(new.year)
        .fetch_one(db.pool())
        .await?)
}

pub async fn find(db: &Db, id: &str) -> Result<Option<MediaItemRow>, DbError> {
    let sql = format!("{SELECT} WHERE id = ?");

    Ok(sqlx::query_as::<_, MediaItemRow>(&sql)
        .bind(id)
        .fetch_optional(db.pool())
        .await?)
}

#[cfg(test)]
mod tests {
    use super::{find, upsert, NewMediaItem};
    use crate::library_paths::sync_from_config;
    use crate::pool::connect_temp;
    use crate::Db;

    async fn library(db: &Db) -> String {
        sync_from_config(db, &[("/media/movies".to_string(), "movies".to_string())])
            .await
            .unwrap()[0]
            .id
            .clone()
    }

    fn new_movie(library_path_id: &str, title: &str, year: Option<i64>) -> NewMediaItem {
        NewMediaItem {
            library_path_id: library_path_id.to_string(),
            media_type: "movie".to_string(),
            title: title.to_string(),
            identity_key: title.to_lowercase().replace(' ', ""),
            year,
        }
    }

    #[tokio::test]
    async fn an_item_is_created_and_found() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let created = upsert(&db, new_movie(&lp, "The Matrix", Some(1999)))
            .await
            .unwrap();

        let found = find(&db, &created.id).await.unwrap().unwrap();

        assert_eq!(found.title, "The Matrix");
        assert_eq!(found.year, Some(1999));
        assert_eq!(found.media_type, "movie");
    }

    #[tokio::test]
    async fn upserting_the_same_item_returns_the_same_row() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let first = upsert(&db, new_movie(&lp, "The Matrix", Some(1999)))
            .await
            .unwrap();
        let second = upsert(&db, new_movie(&lp, "The Matrix", Some(1999)))
            .await
            .unwrap();

        assert_eq!(first.id, second.id, "a rescan must not duplicate the item");
        assert_eq!(
            first.added_at, second.added_at,
            "added_at is when we first saw it"
        );
    }

    #[tokio::test]
    async fn two_items_with_the_same_title_and_different_years_are_distinct() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let a = upsert(&db, new_movie(&lp, "The Thing", Some(1982)))
            .await
            .unwrap();
        let b = upsert(&db, new_movie(&lp, "The Thing", Some(2011)))
            .await
            .unwrap();

        assert_ne!(a.id, b.id);
    }

    #[tokio::test]
    async fn a_year_less_item_upserts_rather_than_duplicating() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let a = upsert(&db, new_movie(&lp, "Untitled", None)).await.unwrap();
        let b = upsert(&db, new_movie(&lp, "Untitled", None)).await.unwrap();

        assert_eq!(a.id, b.id, "COALESCE(year, -1) is what makes this work");
    }

    #[tokio::test]
    async fn a_movie_and_a_show_with_the_same_title_are_distinct() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let movie = upsert(&db, new_movie(&lp, "Fargo", Some(1996)))
            .await
            .unwrap();

        let mut show = new_movie(&lp, "Fargo", Some(1996));
        show.media_type = "tv_show".to_string();
        let show = upsert(&db, show).await.unwrap();

        assert_ne!(movie.id, show.id);
    }

    #[tokio::test]
    async fn an_unknown_id_is_none_not_an_error() {
        let (db, _g) = connect_temp().await.unwrap();

        assert!(find(&db, "no-such-item").await.unwrap().is_none());
    }
}
