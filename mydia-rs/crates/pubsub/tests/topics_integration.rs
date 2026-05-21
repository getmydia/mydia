//! End-to-end check that the canonical topic constants integrate
//! with the broadcast bus correctly. Catches typos / accidental
//! double-keying where a publisher and subscriber drift on the
//! topic string format.

use mydia_rs_pubsub::{topics, Event, Pubsub};
use serde_json::json;
use std::time::Duration;
use tokio::time::timeout;

#[tokio::test]
async fn library_scanner_topic_round_trip() {
    let bus = Pubsub::new();
    let mut rx = bus.subscribe(topics::LIBRARY_SCANNER);

    let event = Event::from_json(json!({
        "kind": "scan_started",
        "library_path_id": "abc-123",
    }));
    let count = bus.publish(topics::LIBRARY_SCANNER, event);
    assert_eq!(count, 1);

    let received = timeout(Duration::from_millis(50), rx.recv())
        .await
        .expect("no timeout")
        .expect("event");
    assert_eq!(received.payload["kind"], "scan_started");
}

#[tokio::test]
async fn device_status_topic_is_user_keyed() {
    let bus = Pubsub::new();
    let user_a = "550e8400-e29b-41d4-a716-446655440000";
    let user_b = "650e8400-e29b-41d4-a716-446655440000";
    let mut rx_a = bus.subscribe(&topics::device_status_for(user_a));
    let mut rx_b = bus.subscribe(&topics::device_status_for(user_b));

    bus.publish(
        &topics::device_status_for(user_a),
        Event::from_json(json!({ "event": "connected" })),
    );

    // user_a sees the event
    let received = timeout(Duration::from_millis(50), rx_a.recv())
        .await
        .expect("rx_a not timed out")
        .expect("event");
    assert_eq!(received.payload["event"], "connected");

    // user_b's receiver sees nothing
    let other = timeout(Duration::from_millis(20), rx_b.recv()).await;
    assert!(other.is_err(), "rx_b should time out (cross-user isolated)");
}

#[tokio::test]
async fn jobs_status_topic_is_singleton() {
    // `jobs:status` is global — every subscriber gets every event.
    let bus = Pubsub::new();
    let mut rx1 = bus.subscribe(topics::JOBS_STATUS);
    let mut rx2 = bus.subscribe(topics::JOBS_STATUS);

    let count = bus.publish(
        topics::JOBS_STATUS,
        Event::from_json(json!({ "executing": 3 })),
    );
    assert_eq!(count, 2, "broadcast reaches both subscribers");

    let r1 = timeout(Duration::from_millis(50), rx1.recv())
        .await
        .expect("rx1 not timed out")
        .expect("event");
    let r2 = timeout(Duration::from_millis(50), rx2.recv())
        .await
        .expect("rx2 not timed out")
        .expect("event");
    assert_eq!(r1.payload, r2.payload);
}
