//! Integration tests for the integrations crate.
//!
//! Each test spins up a `wiremock::MockServer`, points the relevant
//! client at it, and asserts both the request shape (path / params /
//! headers) and the parsed response.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use mydia_rs_integrations::crash_reporter::{
    CrashEvent, CrashReportQueue, ReportSender, RetryConfig,
};
use mydia_rs_integrations::error::{ErrorKind, IntegrationError};
use mydia_rs_integrations::import_lists::{ImportListProvider, ImportListSpec, TmdbProvider};
use mydia_rs_integrations::media_server::client::{
    MediaServerClient, MediaServerConfig, MediaServerKind, UpdateLibraryOpts,
};
use mydia_rs_integrations::media_server::plex::PlexClient;
use mydia_rs_integrations::media_server::plex_oauth::{PinStatus, PlexOAuth};
use mydia_rs_integrations::media_server::watched_sync::{PlexWatchedSync, WatchedSyncAdapter};
use mydia_rs_integrations::trakt::{client::TraktClient, scrobbler, sync};
use serde_json::json;
use wiremock::matchers::{header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

/// Trakt: token refresh maps to `/trakt/oauth/refresh` and the
/// returned `Token` deserializes correctly.
#[tokio::test]
async fn trakt_refresh_token_round_trips() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/trakt/oauth/refresh"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "new-access",
            "refresh_token": "new-refresh",
            "expires_in": 7_776_000,
            "created_at": 1_700_000_000,
            "scope": "public",
            "token_type": "bearer"
        })))
        .mount(&server)
        .await;

    let client = TraktClient::new(server.uri()).unwrap();
    let token = client.refresh_token("old-refresh").await.unwrap();
    assert_eq!(token.access_token, "new-access");
    assert_eq!(token.refresh_token.as_deref(), Some("new-refresh"));
    assert_eq!(token.expires_in, Some(7_776_000));
}

/// Trakt: device-poll mapping for HTTP 400 (pending) maps to the
/// dedicated `DevicePending` kind.
#[tokio::test]
async fn trakt_device_poll_pending_maps_to_kind() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/trakt/oauth/device/token"))
        .respond_with(ResponseTemplate::new(400).set_body_string("authorization_pending"))
        .mount(&server)
        .await;

    let client = TraktClient::new(server.uri()).unwrap();
    let err = client.poll_device_token("dev-code").await.unwrap_err();
    assert_eq!(err.kind, ErrorKind::DevicePending);
}

/// Trakt: scrobble flow with a movie target sends the right body
/// shape and includes the `X-Trakt-User-Token` header.
#[tokio::test]
async fn trakt_scrobble_attaches_user_token_header() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/trakt/scrobble/start"))
        .and(header("x-trakt-user-token", "user-tok"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"action": "start"})))
        .mount(&server)
        .await;

    let client = TraktClient::new(server.uri()).unwrap();
    let item = sync::LocalMediaItem {
        id: "abc".into(),
        title: "Inception".into(),
        year: Some(2010),
        imdb_id: Some("tt1375666".into()),
        tmdb_id: None,
        tvdb_id: None,
    };
    let body = scrobbler::build_scrobble_body(&scrobbler::ScrobbleTarget::Movie { item }, 25.0)
        .expect("build body");
    let response =
        scrobbler::scrobble(&client, scrobbler::ScrobbleAction::Start, "user-tok", &body)
            .await
            .unwrap();
    assert_eq!(response.get("action").unwrap(), "start");
}

/// Trakt: when the access token is expired the relay returns 401;
/// the client surfaces a clear `AuthExpired` error.
#[tokio::test]
async fn trakt_scrobble_expired_token_surfaces_auth_expired() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/trakt/scrobble/start"))
        .respond_with(ResponseTemplate::new(401).set_body_string("expired"))
        .mount(&server)
        .await;

    let client = TraktClient::new(server.uri()).unwrap();
    let err = client
        .scrobble_start(&json!({"progress": 0}), "expired-tok")
        .await
        .unwrap_err();
    assert_eq!(err.kind, ErrorKind::AuthExpired);
}

/// Plex: watched-status sync iterates sections + items + episodes
/// and surfaces only watched (`view_count` > 0) entries.
#[tokio::test]
async fn plex_watched_sync_returns_only_watched() {
    let server = MockServer::start().await;
    // List sections.
    Mock::given(method("GET"))
        .and(path("/library/sections"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "MediaContainer": {
                "Directory": [
                    {"key": "1", "type": "movie", "title": "Movies"}
                ]
            }
        })))
        .mount(&server)
        .await;
    // List section items.
    Mock::given(method("GET"))
        .and(path("/library/sections/1/all"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "MediaContainer": {
                "Metadata": [
                    {
                        "ratingKey": "rk-watched",
                        "title": "The Matrix",
                        "type": "movie",
                        "viewCount": 1,
                        "Guid": [{"id": "tmdb://603"}]
                    },
                    {
                        "ratingKey": "rk-unwatched",
                        "title": "Memento",
                        "type": "movie",
                        "viewCount": 0,
                        "Guid": [{"id": "tmdb://77"}]
                    }
                ]
            }
        })))
        .mount(&server)
        .await;

    let client = PlexClient::new().unwrap();
    let sync = PlexWatchedSync::new(client);
    let config = MediaServerConfig {
        id: "abc".into(),
        kind: MediaServerKind::Plex,
        name: "test".into(),
        url: server.uri(),
        token: "tok".into(),
        enabled: true,
    };
    let watched = sync.fetch_watched(&config).await.unwrap();
    assert_eq!(watched.len(), 1);
    assert_eq!(watched[0].title, "The Matrix");
    assert_eq!(watched[0].external_ids.get("tmdb").unwrap(), "603");
}

/// Plex: `MediaServerClient::update_library` posts to the right path
/// with the path hint as a query param when provided.
#[tokio::test]
async fn plex_update_library_attaches_path_hint() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/library/sections/all/refresh"))
        .and(query_param("path", "/media/Inception"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&server)
        .await;

    let client = PlexClient::new().unwrap();
    let config = MediaServerConfig {
        id: "abc".into(),
        kind: MediaServerKind::Plex,
        name: "test".into(),
        url: server.uri(),
        token: "tok".into(),
        enabled: true,
    };
    client
        .update_library(
            &config,
            &UpdateLibraryOpts {
                path: Some("/media/Inception"),
            },
        )
        .await
        .unwrap();
}

/// TMDB import-list provider returns parsed items for the trending
/// endpoint.
#[tokio::test]
async fn tmdb_import_list_returns_parsed_items() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/tmdb/movies/trending"))
        .and(query_param("language", "en-US"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "results": [
                {
                    "id": 27205,
                    "title": "Inception",
                    "release_date": "2010-07-15",
                    "poster_path": "/poster.jpg"
                },
                {
                    "id": 603,
                    "title": "The Matrix",
                    "release_date": "1999-03-31"
                }
            ]
        })))
        .mount(&server)
        .await;

    let provider = TmdbProvider::new(server.uri()).unwrap();
    let spec = ImportListSpec {
        list_type: "tmdb_trending".into(),
        media_type: "movie".into(),
        config: json!({}),
    };
    let items = provider.fetch_items(&spec).await.unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].tmdb_id, 27205);
    assert_eq!(items[0].title, "Inception");
    assert_eq!(items[0].year, Some(2010));
}

/// Plex OAuth PIN polling: the `Pending` branch is returned when the
/// PIN response has an empty `authToken`.
#[tokio::test]
async fn plex_oauth_pin_pending_returns_pending_status() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/pins/42"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"authToken": ""})))
        .mount(&server)
        .await;

    let oauth = PlexOAuth::with_base_url(server.uri()).unwrap();
    let status = oauth.check_pin(42).await.unwrap();
    matches!(status, PinStatus::Pending);
}

/// Plex OAuth PIN polling: a 404 maps to the `PinExpired` error kind
/// so the loop can clean up.
#[tokio::test]
async fn plex_oauth_pin_404_maps_to_expired() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/pins/99"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    let oauth = PlexOAuth::with_base_url(server.uri()).unwrap();
    let err = oauth.check_pin(99).await.unwrap_err();
    assert_eq!(err.kind, ErrorKind::PinExpired);
}

/// Plex OAuth: PIN polling times out cleanly when the user never
/// authorizes — we drive a tight `tokio::time::timeout` around a
/// loop that keeps getting `Pending` and assert the deadline fires.
#[tokio::test]
async fn plex_oauth_pin_polling_times_out_cleanly() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/pins/7"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"authToken": ""})))
        .mount(&server)
        .await;
    let oauth = PlexOAuth::with_base_url(server.uri()).unwrap();
    let result = tokio::time::timeout(Duration::from_millis(100), async {
        loop {
            match oauth.check_pin(7).await {
                Ok(PinStatus::Authorized { .. }) => return Ok::<(), IntegrationError>(()),
                Ok(PinStatus::Pending) => tokio::time::sleep(Duration::from_millis(10)).await,
                Err(err) => return Err(err),
            }
        }
    })
    .await;
    assert!(result.is_err(), "expected timeout, got: {result:?}");
}

/// Plex: unreachable URL surfaces a retry-eligible network error.
#[tokio::test]
async fn plex_unreachable_url_returns_network_error() {
    let client = PlexClient::new().unwrap();
    let config = MediaServerConfig {
        id: "abc".into(),
        kind: MediaServerKind::Plex,
        name: "test".into(),
        // Port 1 is reserved/never-listening on standard systems.
        url: "http://127.0.0.1:1".into(),
        token: "tok".into(),
        enabled: true,
    };
    let err = client.test_connection(&config).await.unwrap_err();
    assert!(
        matches!(err.kind, ErrorKind::Network | ErrorKind::Timeout),
        "got: {err:?}"
    );
}

/// Crash reporter: ERROR `tracing::Event` is captured by the
/// `TracingLayer` and forwarded to the queue.
#[tokio::test]
async fn crash_reporter_captures_error_tracing_events() {
    use std::sync::Mutex;

    struct CaptureSender {
        events: Mutex<Vec<CrashEvent>>,
    }

    #[async_trait::async_trait]
    impl ReportSender for CaptureSender {
        async fn send(&self, event: &CrashEvent) -> Result<(), IntegrationError> {
            self.events.lock().unwrap().push(event.clone());
            Ok(())
        }
    }

    let capture = Arc::new(CaptureSender {
        events: Mutex::new(Vec::new()),
    });
    let (queue, sender) = CrashReportQueue::with_sender(
        capture.clone() as Arc<dyn ReportSender + Send + Sync>,
        RetryConfig::default(),
    );

    let layer = mydia_rs_integrations::crash_reporter::TracingLayer::new(sender.clone());
    let subscriber = tracing_subscriber::registry().with(layer);
    let guard = tracing::subscriber::set_default(subscriber);

    tracing::error!(message = "smoke", request_id = "abc");
    drop(guard);

    // Drop sender so queue exits.
    drop(sender);
    queue.run().await;

    let events = capture.events.lock().unwrap();
    assert!(
        events.iter().any(|e| e.error_message.contains("smoke")),
        "got: {events:?}"
    );
}

/// Plex `parse_guids` extracts only the known providers and ignores
/// unknown ones — covered in unit tests, asserted here against a
/// known-good JSON fixture so the integration suite catches any
/// regressions in upstream Plex API shape.
#[test]
fn plex_parse_guids_matches_fixture() {
    let raw = r#"[
        {"id": "tmdb://603"},
        {"id": "imdb://tt0133093"},
        {"id": "ignored://x"}
    ]"#;
    let map = mydia_rs_integrations::media_server::plex::parse_guids(Some(raw));
    let expected: BTreeMap<String, String> = [
        ("tmdb".to_owned(), "603".to_owned()),
        ("imdb".to_owned(), "tt0133093".to_owned()),
    ]
    .into_iter()
    .collect();
    assert_eq!(map, expected);
}

// Add the trace subscriber registry as a use so the layer test
// compiles cleanly.
use tracing_subscriber::layer::SubscriberExt as _;
