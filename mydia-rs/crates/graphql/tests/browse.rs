//! U10.a integration test — browse resolvers against a Phoenix-shaped
//! `SQLite` fixture.
//!
//! Each test builds an in-process `SQLite` DB matching the relevant
//! Phoenix tables, seeds rows that resemble the player's typical
//! browse output, then runs the GraphQL operations through the
//! merged schema. Asserts the response shapes match Phoenix:
//!
//! - Connection cursors are base64 of `cursor:<offset>` (the
//!   `BrowseResolver.encode_cursor/1` byte shape).
//! - Edge nodes carry encoded global IDs (`movie:<uuid>`).
//! - `PageInfo` has the expected boolean shape on first/last pages.

mod common;

use async_graphql::{Request, Variables};
use mydia_rs_db::types::UuidText;
use serde_json::json;
use uuid::Uuid;

use common::{
    build_test_schema, fresh_browse_db, sample_dt, seed_episode, seed_library_path, seed_movie,
    seed_tv_show,
};

#[tokio::test]
async fn movies_query_returns_seeded_rows_with_phoenix_cursor() {
    let db = fresh_browse_db().await;

    let id_a = UuidText::new_v4();
    let id_b = UuidText::new_v4();
    seed_movie(&db, id_a, "Arrival", 2016, 7.5, sample_dt(2024, 1, 1)).await;
    seed_movie(&db, id_b, "Dune", 2021, 8.0, sample_dt(2024, 2, 1)).await;

    let schema = build_test_schema(db);

    let response = schema
        .execute(
            r"
            {
                movies(first: 10) {
                    totalCount
                    pageInfo { hasNextPage hasPreviousPage startCursor endCursor }
                    edges {
                        cursor
                        node { id title year }
                    }
                }
            }
            ",
        )
        .await;

    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();

    assert_eq!(data["movies"]["totalCount"], 2);
    assert_eq!(data["movies"]["pageInfo"]["hasNextPage"], false);
    assert_eq!(data["movies"]["pageInfo"]["hasPreviousPage"], false);

    // Phoenix cursor for offset 0 is base64("cursor:0") = "Y3Vyc29yOjA=".
    assert_eq!(data["movies"]["pageInfo"]["startCursor"], "Y3Vyc29yOjA=");
    assert_eq!(data["movies"]["pageInfo"]["endCursor"], "Y3Vyc29yOjE=");

    let edges = data["movies"]["edges"].as_array().unwrap();
    assert_eq!(edges.len(), 2);
    // Default sort is title ASC, so Arrival comes before Dune.
    assert_eq!(edges[0]["node"]["title"], "Arrival");
    assert_eq!(edges[0]["cursor"], "Y3Vyc29yOjA=");
    assert!(edges[0]["node"]["id"]
        .as_str()
        .unwrap()
        .starts_with("movie:"));
    assert_eq!(edges[1]["node"]["title"], "Dune");
}

#[tokio::test]
async fn movies_query_paginates_using_after_cursor() {
    let db = fresh_browse_db().await;

    for (i, title) in ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
        .iter()
        .enumerate()
    {
        seed_movie(
            &db,
            UuidText::new_v4(),
            title,
            2020 + i as i32,
            5.0 + i as f64,
            sample_dt(2024, 1, 1 + i as u32),
        )
        .await;
    }

    let schema = build_test_schema(db);

    // First page of 2 — should include Alpha, Beta (title ASC).
    let resp1 = schema
        .execute(
            r"{ movies(first: 2) { pageInfo { endCursor hasNextPage } edges { node { title } } } }",
        )
        .await;
    assert!(resp1.errors.is_empty(), "errors: {:?}", resp1.errors);
    let data1 = resp1.data.into_json().unwrap();
    assert_eq!(data1["movies"]["pageInfo"]["hasNextPage"], true);
    let cursor = data1["movies"]["pageInfo"]["endCursor"]
        .as_str()
        .unwrap()
        .to_owned();

    // Second page using the prior cursor.
    let query = format!(
        r#"{{ movies(first: 2, after: "{cursor}") {{ pageInfo {{ hasPreviousPage hasNextPage }} edges {{ node {{ title }} }} }} }}"#
    );
    let resp2 = schema.execute(&*query).await;
    assert!(resp2.errors.is_empty(), "errors: {:?}", resp2.errors);
    let data2 = resp2.data.into_json().unwrap();
    let titles: Vec<String> = data2["movies"]["edges"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["node"]["title"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(titles, vec!["Delta", "Epsilon"]); // sorted: Alpha Beta Delta Epsilon Gamma
    assert_eq!(data2["movies"]["pageInfo"]["hasPreviousPage"], true);
    assert_eq!(data2["movies"]["pageInfo"]["hasNextPage"], true);
}

#[tokio::test]
async fn movies_sort_year_desc() {
    let db = fresh_browse_db().await;

    seed_movie(
        &db,
        UuidText::new_v4(),
        "Old Movie",
        1990,
        5.0,
        sample_dt(2024, 1, 1),
    )
    .await;
    seed_movie(
        &db,
        UuidText::new_v4(),
        "Newer",
        2020,
        7.0,
        sample_dt(2024, 1, 2),
    )
    .await;

    let schema = build_test_schema(db);

    let resp = schema
        .execute(
            r"{ movies(first: 10, sort: { field: YEAR, direction: DESC }) {
                  edges { node { title year } } } }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let titles: Vec<String> = data["movies"]["edges"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["node"]["title"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(titles, vec!["Newer", "Old Movie"]);
}

#[tokio::test]
async fn tv_shows_query_filters_correctly() {
    use mydia_rs_db::insert_active_model;
    use mydia_rs_db::types::DateTimeSecs;
    use mydia_rs_entities::media_files;
    use sea_orm::Set;

    let db = fresh_browse_db().await;

    seed_movie(
        &db,
        UuidText::new_v4(),
        "A Movie",
        2020,
        7.0,
        sample_dt(2024, 1, 1),
    )
    .await;
    // Need to seed a media_file for the TV show too so `has_files` matches.
    let show_id = UuidText::new_v4();
    seed_tv_show(&db, show_id, "Some Show", 2018, sample_dt(2024, 1, 1)).await;

    let now: DateTimeSecs = sample_dt(2024, 1, 1);
    let file_id = UuidText::new_v4();
    let am = media_files::ActiveModel {
        id: Set(file_id),
        media_item_id: Set(Some(show_id)),
        episode_id: Set(None),
        path: Set(None),
        size: Set(None),
        quality_profile_id: Set(None),
        resolution: Set(None),
        codec: Set(None),
        hdr_format: Set(None),
        audio_codec: Set(None),
        bitrate: Set(None),
        verified_at: Set(None),
        metadata: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
        library_path_id: Set(None),
        relative_path: Set(None),
        cover_blob: Set(None),
        sprite_blob: Set(None),
        vtt_blob: Set(None),
        preview_blob: Set(None),
        phash: Set(None),
        generated_at: Set(None),
        trashed_at: Set(None),
        analyzed_at: Set(None),
        analysis_attempts: Set(0),
        last_analysis_error: Set(None),
    };
    insert_active_model(am, &db).await.unwrap();

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{
                movies(first: 10) { totalCount edges { node { title } } }
                tvShows(first: 10) { totalCount edges { node { title } } }
            }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["movies"]["totalCount"], 1);
    assert_eq!(data["tvShows"]["totalCount"], 1);
    assert_eq!(data["tvShows"]["edges"][0]["node"]["title"], "Some Show");
}

#[tokio::test]
async fn movie_by_id_handles_both_encoded_and_raw_uuid() {
    let db = fresh_browse_db().await;
    let movie_uuid = Uuid::new_v4();
    let id = UuidText::from(movie_uuid);
    seed_movie(&db, id, "Pinned", 2024, 7.0, sample_dt(2024, 1, 1)).await;

    let schema = build_test_schema(db);

    const MOVIE_QUERY: &str = r"query M($id: ID!) { movie(id: $id) { title } }";

    // Encoded form.
    let encoded = format!("movie:{movie_uuid}");
    let resp = schema
        .execute(Request::new(MOVIE_QUERY).variables(Variables::from_json(json!({"id": encoded}))))
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    assert_eq!(resp.data.into_json().unwrap()["movie"]["title"], "Pinned");

    // Raw UUID form.
    let resp_raw = schema
        .execute(
            Request::new(MOVIE_QUERY)
                .variables(Variables::from_json(json!({"id": movie_uuid.to_string()}))),
        )
        .await;
    assert!(resp_raw.errors.is_empty(), "errors: {:?}", resp_raw.errors);
    assert_eq!(
        resp_raw.data.into_json().unwrap()["movie"]["title"],
        "Pinned"
    );
}

#[tokio::test]
async fn movie_by_wrong_kind_id_rejects() {
    let db = fresh_browse_db().await;
    let schema = build_test_schema(db);
    let resp = schema
        .execute(r#"{ movie(id: "show:abc") { title } }"#)
        .await;
    assert!(!resp.errors.is_empty(), "expected error");
    assert!(resp.errors[0].message.contains("Invalid"));
}

#[tokio::test]
async fn libraries_returns_seeded_paths() {
    let db = fresh_browse_db().await;
    let id = UuidText::new_v4();
    seed_library_path(&db, id, "/media/movies", "movies", sample_dt(2024, 1, 1)).await;
    let id2 = UuidText::new_v4();
    seed_library_path(&db, id2, "/media/tv", "series", sample_dt(2024, 1, 1)).await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(r"{ libraries { id path type monitored } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let libraries = data["libraries"].as_array().unwrap();
    assert_eq!(libraries.len(), 2);
    let types: Vec<String> = libraries
        .iter()
        .map(|l| l["type"].as_str().unwrap().to_owned())
        .collect();
    assert!(types.contains(&"MOVIES".to_owned()));
    assert!(types.contains(&"SERIES".to_owned()));
    assert!(libraries[0]["id"].as_str().unwrap().starts_with("library:"));
}

#[tokio::test]
async fn season_query_aggregates_episodes() {
    let db = fresh_browse_db().await;
    let show_id = UuidText::new_v4();
    seed_tv_show(&db, show_id, "Show", 2020, sample_dt(2024, 1, 1)).await;
    for ep_num in 1..=3 {
        seed_episode(
            &db,
            UuidText::new_v4(),
            show_id,
            1,
            ep_num,
            &format!("Ep {ep_num}"),
            sample_dt(2024, 1, ep_num as u32),
        )
        .await;
    }

    let schema = build_test_schema(db);
    let show_uuid_str = show_id.0.to_string();
    let resp = schema
        .execute(
            Request::new(
                r"query S($id: ID!) {
                season(showId: $id, seasonNumber: 1) {
                    id seasonNumber episodeCount hasFiles
                }
            }",
            )
            .variables(Variables::from_json(json!({"id": show_uuid_str.clone()}))),
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["season"]["seasonNumber"], 1);
    assert_eq!(data["season"]["episodeCount"], 3);
    assert_eq!(data["season"]["hasFiles"], false);
    let expected_id = format!("season:{show_uuid_str}:1");
    assert_eq!(data["season"]["id"], expected_id);
}

#[tokio::test]
async fn season_episodes_query() {
    let db = fresh_browse_db().await;
    let show_id = UuidText::new_v4();
    seed_tv_show(&db, show_id, "Show", 2020, sample_dt(2024, 1, 1)).await;
    for ep_num in [1, 2] {
        seed_episode(
            &db,
            UuidText::new_v4(),
            show_id,
            1,
            ep_num,
            &format!("S1E{ep_num}"),
            sample_dt(2024, 1, ep_num as u32),
        )
        .await;
    }
    seed_episode(
        &db,
        UuidText::new_v4(),
        show_id,
        2,
        1,
        "S2E1",
        sample_dt(2024, 2, 1),
    )
    .await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            Request::new(
                r"query E($id: ID!) {
                seasonEpisodes(showId: $id, seasonNumber: 1) {
                    seasonNumber episodeNumber title
                }
            }",
            )
            .variables(Variables::from_json(json!({"id": show_id.0.to_string()}))),
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let eps = data["seasonEpisodes"].as_array().unwrap();
    assert_eq!(eps.len(), 2);
    assert_eq!(eps[0]["episodeNumber"], 1);
    assert_eq!(eps[1]["episodeNumber"], 2);
}

#[tokio::test]
async fn node_query_dispatches_by_type() {
    let db = fresh_browse_db().await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", 2020, 7.0, sample_dt(2024, 1, 1)).await;

    let schema = build_test_schema(db);
    let encoded = format!("movie:{}", movie_id.0);
    let resp = schema
        .execute(
            Request::new(
                r"query N($id: ID!) {
                node(id: $id) { __typename ... on Movie { title } }
            }",
            )
            .variables(Variables::from_json(json!({"id": encoded}))),
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["node"]["__typename"], "Movie");
    assert_eq!(data["node"]["title"], "M");
}
