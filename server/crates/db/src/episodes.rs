use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct EpisodeRow {
    pub id: String,
    pub show_id: String,
    pub season_number: i64,
    pub episode_number: i64,
    pub title: Option<String>,
    pub overview: Option<String>,
    pub air_date: Option<String>,
    pub runtime: Option<i64>,
    pub thumbnail_url: Option<String>,
    pub added_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct NewEpisode {
    pub show_id: String,
    pub season_number: i64,
    pub episode_number: i64,
}

const SELECT: &str = "SELECT id, show_id, season_number, episode_number, title, overview,
                             air_date, runtime, thumbnail_url, added_at, updated_at
                      FROM episodes";

/// Creates the episode or returns the existing one. Slice 2a knows only its
/// numbering; titles, overviews and air dates arrive with Slice 2b, which is
/// why nothing here is overwritten on conflict.
pub async fn upsert(db: &Db, new: NewEpisode) -> Result<EpisodeRow, DbError> {
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO episodes
           (id, show_id, season_number, episode_number, added_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT (show_id, season_number, episode_number)
         DO UPDATE SET updated_at = excluded.updated_at",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(&new.show_id)
    .bind(new.season_number)
    .bind(new.episode_number)
    .bind(&now)
    .bind(&now)
    .execute(db.pool())
    .await?;

    let sql = format!("{SELECT} WHERE show_id = ? AND season_number = ? AND episode_number = ?");

    Ok(sqlx::query_as::<_, EpisodeRow>(&sql)
        .bind(&new.show_id)
        .bind(new.season_number)
        .bind(new.episode_number)
        .fetch_one(db.pool())
        .await?)
}

pub async fn find(db: &Db, id: &str) -> Result<Option<EpisodeRow>, DbError> {
    let sql = format!("{SELECT} WHERE id = ?");

    Ok(sqlx::query_as::<_, EpisodeRow>(&sql)
        .bind(id)
        .fetch_optional(db.pool())
        .await?)
}

pub async fn list_for_show(db: &Db, show_id: &str) -> Result<Vec<EpisodeRow>, DbError> {
    let sql = format!("{SELECT} WHERE show_id = ? ORDER BY season_number, episode_number");

    Ok(sqlx::query_as::<_, EpisodeRow>(&sql)
        .bind(show_id)
        .fetch_all(db.pool())
        .await?)
}

/// Ordered by episode number, matching browse_resolver.ex:154.
pub async fn list_for_season(
    db: &Db,
    show_id: &str,
    season_number: i64,
) -> Result<Vec<EpisodeRow>, DbError> {
    let sql = format!("{SELECT} WHERE show_id = ? AND season_number = ? ORDER BY episode_number");

    Ok(sqlx::query_as::<_, EpisodeRow>(&sql)
        .bind(show_id)
        .bind(season_number)
        .fetch_all(db.pool())
        .await?)
}

#[cfg(test)]
mod tests {
    use super::{find, list_for_season, list_for_show, upsert, NewEpisode};
    use crate::library_paths::sync_from_config;
    use crate::media_items::{upsert as upsert_item, NewMediaItem};
    use crate::pool::connect_temp;
    use crate::Db;

    async fn show(db: &Db) -> String {
        let lp = sync_from_config(db, &[("/media/tv".to_string(), "series".to_string())])
            .await
            .unwrap()[0]
            .id
            .clone();

        upsert_item(
            db,
            NewMediaItem {
                library_path_id: lp,
                media_type: "tv_show".to_string(),
                title: "Show Name".to_string(),
                identity_key: "showname".to_string(),
                year: None,
            },
        )
        .await
        .unwrap()
        .id
    }

    fn episode(show_id: &str, season: i64, number: i64) -> NewEpisode {
        NewEpisode {
            show_id: show_id.to_string(),
            season_number: season,
            episode_number: number,
        }
    }

    #[tokio::test]
    async fn an_episode_is_created_and_found() {
        let (db, _g) = connect_temp().await.unwrap();
        let show_id = show(&db).await;

        let created = upsert(&db, episode(&show_id, 1, 2)).await.unwrap();
        let found = find(&db, &created.id).await.unwrap().unwrap();

        assert_eq!(found.season_number, 1);
        assert_eq!(found.episode_number, 2);
    }

    #[tokio::test]
    async fn upserting_the_same_episode_returns_the_same_row() {
        let (db, _g) = connect_temp().await.unwrap();
        let show_id = show(&db).await;

        let first = upsert(&db, episode(&show_id, 1, 2)).await.unwrap();
        let second = upsert(&db, episode(&show_id, 1, 2)).await.unwrap();

        assert_eq!(first.id, second.id);
    }

    #[tokio::test]
    async fn episodes_list_in_season_then_episode_order() {
        let (db, _g) = connect_temp().await.unwrap();
        let show_id = show(&db).await;

        for (season, number) in [(2, 1), (1, 10), (1, 2), (0, 1)] {
            upsert(&db, episode(&show_id, season, number))
                .await
                .unwrap();
        }

        let listed = list_for_show(&db, &show_id).await.unwrap();
        let pairs: Vec<(i64, i64)> = listed
            .iter()
            .map(|e| (e.season_number, e.episode_number))
            .collect();

        assert_eq!(pairs, vec![(0, 1), (1, 2), (1, 10), (2, 1)]);
    }

    #[tokio::test]
    async fn a_season_lists_only_its_own_episodes_in_order() {
        let (db, _g) = connect_temp().await.unwrap();
        let show_id = show(&db).await;

        for (season, number) in [(1, 2), (1, 1), (2, 1)] {
            upsert(&db, episode(&show_id, season, number))
                .await
                .unwrap();
        }

        let listed = list_for_season(&db, &show_id, 1).await.unwrap();
        let numbers: Vec<i64> = listed.iter().map(|e| e.episode_number).collect();

        assert_eq!(numbers, vec![1, 2]);
    }

    #[tokio::test]
    async fn deleting_the_show_removes_its_episodes() {
        let (db, _g) = connect_temp().await.unwrap();
        let show_id = show(&db).await;
        upsert(&db, episode(&show_id, 1, 1)).await.unwrap();

        sqlx::query("DELETE FROM media_items WHERE id = ?")
            .bind(&show_id)
            .execute(db.pool())
            .await
            .unwrap();

        assert!(list_for_show(&db, &show_id).await.unwrap().is_empty());
    }
}
