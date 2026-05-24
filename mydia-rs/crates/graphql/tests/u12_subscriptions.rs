//! U12 integration tests — `progressUpdated` and
//! `deviceStatusChanged` subscriptions.
//!
//! async-graphql exposes subscriptions through `Schema::execute_stream`,
//! which returns a stream of Responses. The tests drive the bus via
//! `Pubsub::publish` and assert the subscriber sees the same payload.

mod common;

use std::time::Duration;

use async_graphql::futures_util::StreamExt;
use async_graphql::{Request, Variables};
use mydia_rs_auth::role::Role;
use mydia_rs_graphql::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use mydia_rs_graphql::{build_schema, MydiaSchema};
use mydia_rs_pubsub::{Event, Pubsub};
use sea_orm::DatabaseConnection;
use serde_json::json;
use uuid::Uuid;

use common::fresh_playback_db;

fn user(id: Uuid, username: &str, role: Role) -> CurrentUser {
    CurrentUser {
        id,
        username: username.to_owned(),
        role,
    }
}

fn build_state_with_pubsub(db: DatabaseConnection) -> (GraphqlAppState, Pubsub) {
    let bus = Pubsub::new();
    let state = GraphqlAppState::with_pubsub(db, bus.clone());
    (state, bus)
}

/// Helper: subscribe to a subscription operation as a particular user
/// and return the first response within `timeout`. Returns `None` if
/// no response arrives in time.
async fn first_response(
    schema: &MydiaSchema,
    user: CurrentUser,
    query: &str,
    variables: Variables,
    timeout: Duration,
) -> Option<async_graphql::Response> {
    let request = Request::new(query)
        .variables(variables)
        .data(GraphqlRequestContext::with_user(user));
    let mut stream = schema.execute_stream(request);
    tokio::time::timeout(timeout, stream.next())
        .await
        .ok()
        .flatten()
}

fn progress_payload(position: i32, duration: i32) -> serde_json::Value {
    json!({
        "position_seconds": position,
        "duration_seconds": duration,
        "percentage": (f64::from(position) / f64::from(duration)) * 100.0,
        "watched": false,
        "last_watched_at": "2024-01-01T00:00:00Z"
    })
}

// ──────────── progressUpdated ────────────────────────────────────

#[tokio::test]
async fn progress_subscription_yields_event_for_movie_topic() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice = user(Uuid::new_v4(), "alice", Role::User);
    let movie_uuid = Uuid::new_v4().to_string();
    let encoded_id = format!("movie:{movie_uuid}");

    let request = Request::new(
        r"subscription Sub($id: ID!) {
            progressUpdated(nodeId: $id) {
                positionSeconds durationSeconds percentage watched
            }
        }",
    )
    .variables(Variables::from_json(json!({"id": encoded_id.clone()})))
    .data(GraphqlRequestContext::with_user(alice));

    let mut stream = schema.execute_stream(request);
    // Yield the runtime so the subscription registers its receiver.
    tokio::task::yield_now().await;

    // Spawn a publisher that pushes one event onto the bus.
    let bus_clone = bus.clone();
    let topic = encoded_id.clone();
    let publish_handle = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic, Event::from_json(progress_payload(120, 600)));
    });

    let response = tokio::time::timeout(Duration::from_secs(2), stream.next())
        .await
        .expect("subscription timed out")
        .expect("subscription closed");
    publish_handle.await.unwrap();

    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["progressUpdated"]["positionSeconds"], 120);
    assert_eq!(data["progressUpdated"]["durationSeconds"], 600);
    assert!((data["progressUpdated"]["percentage"].as_f64().unwrap() - 20.0).abs() < 1e-9);
}

#[tokio::test]
async fn progress_subscription_filters_by_topic() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice = user(Uuid::new_v4(), "alice", Role::User);
    let movie_a = format!("movie:{}", Uuid::new_v4());
    let movie_b = format!("movie:{}", Uuid::new_v4());

    let request = Request::new(
        r"subscription S($id: ID!) {
            progressUpdated(nodeId: $id) { positionSeconds }
        }",
    )
    .variables(Variables::from_json(json!({"id": movie_a.clone()})))
    .data(GraphqlRequestContext::with_user(alice));
    let mut stream = schema.execute_stream(request);

    // First publish — on the wrong topic.
    let bus_clone = bus.clone();
    let topic_wrong = movie_b.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic_wrong, Event::from_json(progress_payload(1, 100)));
    });
    let none = tokio::time::timeout(Duration::from_millis(150), stream.next()).await;
    assert!(none.is_err(), "should not have received an event");

    // Now publish on the right topic.
    bus.publish(&movie_a, Event::from_json(progress_payload(60, 600)));
    let response = tokio::time::timeout(Duration::from_secs(1), stream.next())
        .await
        .expect("timed out")
        .expect("closed");
    assert_eq!(
        response.data.into_json().unwrap()["progressUpdated"]["positionSeconds"],
        60
    );
}

#[tokio::test]
async fn progress_subscription_requires_authentication() {
    let db = fresh_playback_db().await;
    let (state, _bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let request = Request::new(
        r#"subscription { progressUpdated(nodeId: "movie:abc") { positionSeconds } }"#,
    )
    .data(GraphqlRequestContext::anonymous());
    let mut stream = schema.execute_stream(request);
    let response = stream.next().await.expect("first response");
    assert!(!response.errors.is_empty());
    assert!(response.errors[0]
        .message
        .contains("Authentication required"));
}

#[tokio::test]
async fn progress_subscription_drops_malformed_payload() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice = user(Uuid::new_v4(), "alice", Role::User);
    let movie_id = format!("movie:{}", Uuid::new_v4());

    let request = Request::new(
        r"subscription S($id: ID!) {
            progressUpdated(nodeId: $id) { positionSeconds }
        }",
    )
    .variables(Variables::from_json(json!({"id": movie_id.clone()})))
    .data(GraphqlRequestContext::with_user(alice));
    let mut stream = schema.execute_stream(request);

    let bus_clone = bus.clone();
    let topic = movie_id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic, Event::from_json(json!({"banana": "phone"})));
        bus_clone.publish(&topic, Event::from_json(progress_payload(42, 420)));
    });

    let response = tokio::time::timeout(Duration::from_secs(2), stream.next())
        .await
        .expect("timed out")
        .expect("closed");
    assert_eq!(
        response.data.into_json().unwrap()["progressUpdated"]["positionSeconds"],
        42
    );
}

// ──────────── deviceStatusChanged ────────────────────────────────

fn device_payload() -> serde_json::Value {
    json!({
        "device": {
            "id": "device-1",
            "device_name": "Living Room",
            "platform": "android",
            "last_seen_at": "2024-01-01T00:00:00Z",
            "revoked_at": null,
            "inserted_at": "2024-01-01T00:00:00Z"
        },
        "event": "connected"
    })
}

#[tokio::test]
async fn device_status_subscription_yields_event_for_own_user() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice_id = Uuid::new_v4();
    let alice = user(alice_id, "alice", Role::User);

    let request = Request::new(
        r"subscription S($id: ID!) {
            deviceStatusChanged(userId: $id) {
                event
                device { id deviceName platform }
            }
        }",
    )
    .variables(Variables::from_json(json!({"id": alice_id.to_string()})))
    .data(GraphqlRequestContext::with_user(alice));
    let mut stream = schema.execute_stream(request);

    let bus_clone = bus.clone();
    let topic = format!("device_status:{alice_id}");
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic, Event::from_json(device_payload()));
    });

    let response = tokio::time::timeout(Duration::from_secs(2), stream.next())
        .await
        .expect("timed out")
        .expect("closed");
    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["deviceStatusChanged"]["event"], "CONNECTED");
    assert_eq!(
        data["deviceStatusChanged"]["device"]["deviceName"],
        "Living Room"
    );
}

#[tokio::test]
async fn device_status_subscription_rejects_other_user_for_non_admin() {
    let db = fresh_playback_db().await;
    let (state, _bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice = user(Uuid::new_v4(), "alice", Role::User);
    let other_user = Uuid::new_v4().to_string();

    let response = first_response(
        &schema,
        alice,
        r"subscription S($id: ID!) {
            deviceStatusChanged(userId: $id) { event }
        }",
        Variables::from_json(json!({"id": other_user})),
        Duration::from_secs(1),
    )
    .await
    .expect("first response");
    assert!(!response.errors.is_empty(), "expected auth error");
    assert!(response.errors[0]
        .message
        .contains("Cannot subscribe to another user"));
}

#[tokio::test]
async fn device_status_subscription_allows_admin_to_watch_any_user() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let admin = user(Uuid::new_v4(), "root", Role::Admin);
    let target_user = Uuid::new_v4();

    let request =
        Request::new(r"subscription S($id: ID!) { deviceStatusChanged(userId: $id) { event } }")
            .variables(Variables::from_json(json!({"id": target_user.to_string()})))
            .data(GraphqlRequestContext::with_user(admin));
    let mut stream = schema.execute_stream(request);

    let bus_clone = bus.clone();
    let topic = format!("device_status:{target_user}");
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic, Event::from_json(device_payload()));
    });
    let response = tokio::time::timeout(Duration::from_secs(2), stream.next())
        .await
        .expect("timed out")
        .expect("closed");
    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["deviceStatusChanged"]["event"], "CONNECTED");
}

#[tokio::test]
async fn device_status_subscription_requires_authentication() {
    let db = fresh_playback_db().await;
    let (state, _bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let request = Request::new(r#"subscription { deviceStatusChanged(userId: "abc") { event } }"#)
        .data(GraphqlRequestContext::anonymous());
    let mut stream = schema.execute_stream(request);
    let response = stream.next().await.expect("first response");
    assert!(!response.errors.is_empty());
    assert!(response.errors[0]
        .message
        .contains("Authentication required"));
}

#[tokio::test]
async fn two_subscribers_on_different_topics_do_not_cross_talk() {
    let db = fresh_playback_db().await;
    let (state, bus) = build_state_with_pubsub(db);
    let schema = build_schema(state);
    let alice = user(Uuid::new_v4(), "alice", Role::User);
    let topic_a = format!("movie:{}", Uuid::new_v4());
    let topic_b = format!("movie:{}", Uuid::new_v4());

    let req_a = Request::new(
        r"subscription S($id: ID!) { progressUpdated(nodeId: $id) { positionSeconds } }",
    )
    .variables(Variables::from_json(json!({"id": topic_a.clone()})))
    .data(GraphqlRequestContext::with_user(alice.clone()));
    let req_b = Request::new(
        r"subscription S($id: ID!) { progressUpdated(nodeId: $id) { positionSeconds } }",
    )
    .variables(Variables::from_json(json!({"id": topic_b.clone()})))
    .data(GraphqlRequestContext::with_user(alice));

    let mut stream_a = schema.execute_stream(req_a);
    let mut stream_b = schema.execute_stream(req_b);

    let bus_clone = bus.clone();
    let topic_a_pub = topic_a.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        bus_clone.publish(&topic_a_pub, Event::from_json(progress_payload(11, 110)));
    });
    let resp_a = tokio::time::timeout(Duration::from_secs(2), stream_a.next())
        .await
        .expect("timed out")
        .expect("closed");
    assert_eq!(
        resp_a.data.into_json().unwrap()["progressUpdated"]["positionSeconds"],
        11
    );
    // Stream B should NOT have received the topic-A event.
    let resp_b_none = tokio::time::timeout(Duration::from_millis(100), stream_b.next()).await;
    assert!(resp_b_none.is_err(), "stream_b should be empty");
}
