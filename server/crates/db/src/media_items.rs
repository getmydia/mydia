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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowseField {
    Title,
    Year,
    AddedAt,
    Rating,
}

#[derive(Debug, Clone, Copy)]
pub struct BrowseSort {
    pub field: BrowseField,
    /// The Elixir server reverses the ascending sort rather than sorting
    /// descending (browse_resolver.ex:172-176), which moves nulls to the
    /// front. The ORDER BY clauses below reproduce that.
    pub descending: bool,
}

/// A movie has files directly. A show has them through its episodes. Both are
/// what `has_files: true` means in browse_resolver.ex:71,120.
const HAS_FILES: &str = "(
    EXISTS (SELECT 1 FROM media_files f WHERE f.media_item_id = media_items.id)
 OR EXISTS (SELECT 1 FROM media_files f
            JOIN episodes e ON e.id = f.episode_id
            WHERE e.show_id = media_items.id)
)";

fn order_by(sort: BrowseSort) -> &'static str {
    match (sort.field, sort.descending) {
        (BrowseField::Title, false) => "title ASC, id ASC",
        (BrowseField::Title, true) => "title DESC, id DESC",
        // NULL years sort last ascending, because Erlang orders atoms after
        // numbers. Reversing sends them to the front.
        (BrowseField::Year, false) => "(year IS NULL) ASC, year ASC, id ASC",
        (BrowseField::Year, true) => "(year IS NULL) DESC, year DESC, id DESC",
        (BrowseField::AddedAt, false) => "added_at ASC, id ASC",
        (BrowseField::AddedAt, true) => "added_at DESC, id DESC",
        // get_rating/1 answers 0 for a missing rating, so there are no nulls
        // to order around.
        (BrowseField::Rating, false) => "COALESCE(rating, 0) ASC, id ASC",
        (BrowseField::Rating, true) => "COALESCE(rating, 0) DESC, id DESC",
    }
}

pub async fn browse(
    db: &Db,
    media_type: &str,
    sort: BrowseSort,
    limit: i64,
    offset: i64,
) -> Result<Vec<MediaItemRow>, DbError> {
    let sql = format!(
        "{SELECT} WHERE media_type = ? AND {HAS_FILES}
         ORDER BY {} LIMIT ? OFFSET ?",
        order_by(sort)
    );

    Ok(sqlx::query_as::<_, MediaItemRow>(&sql)
        .bind(media_type)
        .bind(limit.max(0))
        .bind(offset.max(0))
        .fetch_all(db.pool())
        .await?)
}

/// Counts everything that matches, not just the page, matching
/// browse_resolver.ex:104,147.
pub async fn count(db: &Db, media_type: &str) -> Result<i64, DbError> {
    let sql = format!("SELECT count(*) FROM media_items WHERE media_type = ? AND {HAS_FILES}");

    Ok(sqlx::query_scalar::<_, i64>(&sql)
        .bind(media_type)
        .fetch_one(db.pool())
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

    use super::{browse, count, BrowseField, BrowseSort};
    use crate::media_files::{upsert as upsert_file, NewMediaFile, Owner};

    async fn with_file(db: &Db, lp: &str, title: &str, year: Option<i64>) -> String {
        let item = upsert(db, new_movie(lp, title, year)).await.unwrap();

        upsert_file(
            db,
            NewMediaFile {
                owner: Owner::Item(item.id.clone()),
                path: format!("/media/{title}.mkv"),
                size: None,
                resolution: None,
                codec: None,
                audio_codec: None,
                hdr_format: None,
                bitrate: None,
                duration_seconds: None,
                container: None,
                width: None,
                height: None,
                subtitle_tracks: None,
                mtime: "2026-01-01T00:00:00Z".to_string(),
            },
        )
        .await
        .unwrap();

        item.id
    }

    fn by_title() -> BrowseSort {
        BrowseSort {
            field: BrowseField::Title,
            descending: false,
        }
    }

    #[tokio::test]
    async fn browsing_returns_only_items_with_files() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        with_file(&db, &lp, "Has Files", Some(2020)).await;
        upsert(&db, new_movie(&lp, "No Files", Some(2020)))
            .await
            .unwrap();

        let listed = browse(&db, "movie", by_title(), 20, 0).await.unwrap();

        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].title, "Has Files");
        assert_eq!(count(&db, "movie").await.unwrap(), 1);
    }

    #[tokio::test]
    async fn browsing_sorts_by_title_ascending_by_default() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        with_file(&db, &lp, "Charlie", Some(2020)).await;
        with_file(&db, &lp, "Alpha", Some(2020)).await;
        with_file(&db, &lp, "Bravo", Some(2020)).await;

        let titles: Vec<String> = browse(&db, "movie", by_title(), 20, 0)
            .await
            .unwrap()
            .into_iter()
            .map(|i| i.title)
            .collect();

        assert_eq!(titles, vec!["Alpha", "Bravo", "Charlie"]);
    }

    #[tokio::test]
    async fn a_null_year_sorts_last_ascending_and_first_descending() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        with_file(&db, &lp, "Undated", None).await;
        with_file(&db, &lp, "Older", Some(1980)).await;
        with_file(&db, &lp, "Newer", Some(2020)).await;

        let ascending: Vec<String> = browse(
            &db,
            "movie",
            BrowseSort {
                field: BrowseField::Year,
                descending: false,
            },
            20,
            0,
        )
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.title)
        .collect();

        // Erlang term order puts atoms after numbers, so nil years land last.
        assert_eq!(ascending, vec!["Older", "Newer", "Undated"]);

        let descending: Vec<String> = browse(
            &db,
            "movie",
            BrowseSort {
                field: BrowseField::Year,
                descending: true,
            },
            20,
            0,
        )
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.title)
        .collect();

        // Descending is the reverse of ascending, so the nulls move to the top.
        assert_eq!(descending, vec!["Undated", "Newer", "Older"]);
    }

    #[tokio::test]
    async fn a_missing_rating_sorts_as_zero() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let rated = with_file(&db, &lp, "Rated", Some(2020)).await;
        with_file(&db, &lp, "Unrated", Some(2020)).await;

        sqlx::query("UPDATE media_items SET rating = 8.5 WHERE id = ?")
            .bind(&rated)
            .execute(db.pool())
            .await
            .unwrap();

        let titles: Vec<String> = browse(
            &db,
            "movie",
            BrowseSort {
                field: BrowseField::Rating,
                descending: true,
            },
            20,
            0,
        )
        .await
        .unwrap()
        .into_iter()
        .map(|i| i.title)
        .collect();

        assert_eq!(titles, vec!["Rated", "Unrated"]);
    }

    #[tokio::test]
    async fn limit_and_offset_page_through() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        for title in ["A", "B", "C", "D"] {
            with_file(&db, &lp, title, Some(2020)).await;
        }

        let page = browse(&db, "movie", by_title(), 2, 2).await.unwrap();
        let titles: Vec<String> = page.into_iter().map(|i| i.title).collect();

        assert_eq!(titles, vec!["C", "D"]);
    }

    #[tokio::test]
    async fn a_show_counts_as_having_files_through_its_episodes() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let show = upsert(
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
        .unwrap();

        let episode = crate::episodes::upsert(
            &db,
            crate::episodes::NewEpisode {
                show_id: show.id,
                season_number: 1,
                episode_number: 1,
            },
        )
        .await
        .unwrap();

        upsert_file(
            &db,
            NewMediaFile {
                owner: Owner::Episode(episode.id),
                path: "/media/e.mkv".to_string(),
                size: None,
                resolution: None,
                codec: None,
                audio_codec: None,
                hdr_format: None,
                bitrate: None,
                duration_seconds: None,
                container: None,
                width: None,
                height: None,
                subtitle_tracks: None,
                mtime: "2026-01-01T00:00:00Z".to_string(),
            },
        )
        .await
        .unwrap();

        assert_eq!(count(&db, "tv_show").await.unwrap(), 1);
        assert_eq!(
            browse(&db, "tv_show", by_title(), 20, 0)
                .await
                .unwrap()
                .len(),
            1
        );
    }
}
