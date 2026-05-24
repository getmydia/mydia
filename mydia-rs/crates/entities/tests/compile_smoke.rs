//! Smoke test that exercises a representative entity through the
//! `SeaORM` API against a live database. Gated on `DATABASE_URL`
//! (Postgres) and `MYDIA_RS_TEST_SQLITE_URL` (`SQLite`). Unset envs
//! skip cleanly so local `cargo test -p mydia-rs-entities` is a no-op
//! without a DB available. CI's `test-postgres` and `test-sqlite`
//! matrices set the appropriate variable and execute the real probe.

use std::env;

use mydia_rs_entities::media_items;
use sea_orm::{Database, EntityTrait, QuerySelect};

fn postgres_url() -> Option<String> {
    env::var("DATABASE_URL")
        .ok()
        .filter(|u| u.starts_with("postgres://") || u.starts_with("postgresql://"))
}

fn sqlite_url() -> Option<String> {
    env::var("MYDIA_RS_TEST_SQLITE_URL")
        .ok()
        .filter(|u| u.starts_with("sqlite:"))
}

#[tokio::test]
async fn media_items_find_against_postgres() {
    let Some(url) = postgres_url() else { return };
    let db = Database::connect(&url).await.expect("connect postgres");
    let _rows = media_items::Entity::find()
        .limit(1)
        .all(&db)
        .await
        .expect("media_items::find returns Ok on Postgres");
}

#[tokio::test]
async fn media_items_find_against_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    let _rows = media_items::Entity::find()
        .limit(1)
        .all(&db)
        .await
        .expect("media_items::find returns Ok on SQLite");
}
