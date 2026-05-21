//! U18 integration tests for the metadata-relay client.
//!
//! These run the real `reqwest` client against a wiremock-rs mock
//! server. Each test asserts both that the HTTP request shape matches
//! what the metadata-relay expects (path + query) and that the
//! response is parsed into the same Rust struct shape the Elixir port
//! relies on.

use mydia_rs_metadata::{
    error::ErrorKind,
    provider::{FetchOpts, Provider, ProviderConfig, SearchOpts, SeasonOpts, TrendingOpts},
    relay::Relay,
    structs::MediaType,
};
use serde_json::json;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn config_for(server: &MockServer) -> ProviderConfig {
    ProviderConfig {
        r#type: "metadata_relay".into(),
        api_key: None,
        base_url: server.uri(),
        options: json!({ "language": "en-US", "include_adult": false, "timeout": 5_000_u64 }),
    }
}

#[tokio::test]
async fn search_returns_parsed_results() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/movies/search"))
        .and(query_param("query", "Inception"))
        .and(query_param("language", "en-US"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "results": [{
                "id": 27205,
                "title": "Inception",
                "original_title": "Inception",
                "release_date": "2010-07-15",
                "overview": "A thief who steals corporate secrets...",
                "poster_path": "/poster.jpg",
                "backdrop_path": "/backdrop.jpg",
                "popularity": 100.0,
                "vote_average": 8.4,
                "vote_count": 33_000
            }]
        })))
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let opts = SearchOpts {
        media_type: Some(MediaType::Movie),
        ..Default::default()
    };
    let results = relay.search(&config, "Inception", &opts).await.unwrap();

    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert_eq!(r.provider_id, "27205");
    assert_eq!(r.title.as_deref(), Some("Inception"));
    assert_eq!(r.year, Some(2010));
    assert_eq!(r.vote_average, Some(8.4));
}

#[tokio::test]
async fn fetch_by_id_returns_media_metadata() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/movies/603"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id": 603,
            "title": "The Matrix",
            "release_date": "1999-03-31",
            "overview": "A computer hacker learns...",
            "runtime": 136,
            "genres": [{"name": "Action"}, {"name": "Science Fiction"}],
            "production_companies": [{"name": "Warner Bros."}],
            "credits": {
                "cast": [{"name": "Keanu Reeves", "character": "Neo", "order": 0}],
                "crew": [{"name": "Lana Wachowski", "job": "Director", "department": "Directing"}]
            },
            "imdb_id": "tt0133093"
        })))
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let opts = FetchOpts {
        media_type: Some(MediaType::Movie),
        ..Default::default()
    };
    let meta = relay.fetch_by_id(&config, "603", &opts).await.unwrap();

    assert_eq!(meta.provider_id, "603");
    assert_eq!(meta.title.as_deref(), Some("The Matrix"));
    assert_eq!(meta.runtime, Some(136));
    assert_eq!(meta.genres, vec!["Action", "Science Fiction"]);
    assert_eq!(meta.cast.len(), 1);
    assert_eq!(meta.crew.len(), 1);
    assert_eq!(meta.imdb_id.as_deref(), Some("tt0133093"));
}

#[tokio::test]
async fn fetch_season_returns_season_data() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/tv/shows/1396/1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "season_number": 1,
            "name": "Season 1",
            "overview": "Walter White begins his transformation",
            "air_date": "2008-01-20",
            "episodes": [
                {
                    "season_number": 1,
                    "episode_number": 1,
                    "name": "Pilot",
                    "overview": "A chemistry teacher...",
                    "air_date": "2008-01-20",
                    "runtime": 58
                },
                {
                    "season_number": 1,
                    "episode_number": 2,
                    "name": "Cat's in the Bag",
                    "air_date": "2008-01-27",
                    "runtime": 48
                }
            ]
        })))
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let season = relay
        .fetch_season(&config, "1396", 1, &SeasonOpts::default())
        .await
        .unwrap();

    assert_eq!(season.season_number, 1);
    assert_eq!(season.episode_count, Some(2));
    assert_eq!(season.episodes.len(), 2);
    assert_eq!(season.episodes[0].name.as_deref(), Some("Pilot"));
}

#[tokio::test]
async fn rate_limited_maps_to_rate_limited_with_retry_after() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/movies/search"))
        .respond_with(
            ResponseTemplate::new(429)
                .insert_header("retry-after", "30")
                .set_body_json(json!({ "error": "rate limit" })),
        )
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let err = relay
        .search(&config, "Dune", &SearchOpts::default())
        .await
        .unwrap_err();
    assert_eq!(err.kind, ErrorKind::RateLimited);
    assert_eq!(err.retry_after(), Some(30));
}

#[tokio::test]
async fn not_found_maps_to_not_found() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/movies/0"))
        .respond_with(
            ResponseTemplate::new(404).set_body_json(json!({ "status_message": "missing" })),
        )
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let err = relay
        .fetch_by_id(
            &config,
            "0",
            &FetchOpts {
                media_type: Some(MediaType::Movie),
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
    assert_eq!(err.kind, ErrorKind::NotFound);
}

#[tokio::test]
async fn network_error_surfaces_as_network_variant() {
    // Point at a port that nothing's listening on. With a short
    // connect timeout this resolves into a connection-failed error.
    let config = ProviderConfig {
        r#type: "metadata_relay".into(),
        api_key: None,
        base_url: "http://127.0.0.1:1".into(),
        options: json!({ "timeout": 500_u64, "connect_timeout": 250_u64 }),
    };

    let relay = Relay::new();
    let err = relay
        .search(&config, "Dune", &SearchOpts::default())
        .await
        .unwrap_err();

    assert!(
        matches!(
            err.kind,
            ErrorKind::Network | ErrorKind::ConnectionFailed | ErrorKind::Timeout
        ),
        "unexpected error kind: {err:?}"
    );
}

#[tokio::test]
async fn fetch_trending_uses_correct_endpoint() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/tmdb/tv/trending"))
        .and(query_param("language", "en-US"))
        .and(query_param("page", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "results": [{
                "id": 1396,
                "name": "Breaking Bad",
                "first_air_date": "2008-01-20",
                "media_type": "tv"
            }]
        })))
        .mount(&server)
        .await;

    let config = config_for(&server);
    let relay = Relay::new();
    let opts = TrendingOpts {
        media_type: Some(MediaType::TvShow),
        ..Default::default()
    };
    let results = relay.fetch_trending(&config, &opts).await.unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].provider_id, "1396");
    assert_eq!(results[0].title.as_deref(), Some("Breaking Bad"));
}
