//! apalis telemetry → `JOBS_STATUS` pubsub bridge.
//!
//! Port of `lib/mydia/jobs/broadcaster.ex`. Phoenix attaches a
//! `:telemetry` handler to the Oban `[:oban, :job, :start | :stop |
//! :exception]` events and re-publishes a "jobs status changed"
//! signal on the `jobs:status` `PubSub` topic. mydia-rs does the same
//! via apalis 0.7's `Monitor::on_event` API.
//!
//! ## Wire shape
//!
//! Both backends publish the same topic — [`mydia_rs_pubsub::topics::JOBS_STATUS`] —
//! so a subscriber doesn't care which engine emitted the event. The
//! payload shape is intentionally minimal: a JSON object with a
//! `kind` field (`"start"`, `"stop"`, `"exception"`) plus identifying
//! metadata (`worker_id`, `task_id` when available).

use apalis::prelude::{Event as ApalisEvent, Worker};
use mydia_rs_pubsub::{topics, Event, Pubsub};

/// Build an apalis `Monitor::on_event` handler that re-publishes job
/// lifecycle events on the `jobs:status` topic. Pass the result to
/// `Monitor::new().on_event(handler)`.
///
/// The handler is `Send + Sync + 'static` so apalis can store it on
/// the monitor; cloning the `Pubsub` handle is `Arc`-cheap, so the
/// closure holds one reference per Monitor.
pub fn make_handler(pubsub: Pubsub) -> impl Fn(Worker<ApalisEvent>) + Send + Sync + 'static {
    move |worker: Worker<ApalisEvent>| {
        let (kind, payload) = describe_event(worker.inner());
        let worker_id = worker.id().to_string();
        let event = Event::from_json(serde_json::json!({
            "kind": kind,
            "worker_id": worker_id,
            "payload": payload,
        }));
        pubsub.publish(topics::JOBS_STATUS, event);
    }
}

/// Map an apalis `Event` to the Phoenix-side `{kind, payload}` pair.
///
/// `kind` mirrors the suffix of Phoenix's
/// `[:oban, :job, :start | :stop | :exception]` triple — what the
/// admin Jobs `LiveView` keys off when rendering status badges.
fn describe_event(event: &ApalisEvent) -> (&'static str, serde_json::Value) {
    match event {
        ApalisEvent::Start => ("start", serde_json::json!({})),
        ApalisEvent::Engage(task_id) => (
            "engage",
            serde_json::json!({ "task_id": task_id.to_string() }),
        ),
        ApalisEvent::Stop => ("stop", serde_json::json!({})),
        ApalisEvent::Exit => ("exit", serde_json::json!({})),
        ApalisEvent::Idle => ("idle", serde_json::json!({})),
        ApalisEvent::Error(err) => ("exception", serde_json::json!({ "error": err.to_string() })),
        ApalisEvent::Custom(msg) => ("custom", serde_json::json!({ "message": msg })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use apalis::prelude::WorkerId;

    #[tokio::test]
    async fn handler_publishes_on_jobs_status() {
        let bus = Pubsub::new();
        let mut rx = bus.subscribe(topics::JOBS_STATUS);
        let handler = make_handler(bus.clone());

        // Synthesize an apalis-shape Worker<Event> directly. apalis
        // 0.7 exposes `Worker::new(id, state)` publicly.
        let worker = Worker::new(WorkerId::new("library_scanner"), ApalisEvent::Start);
        handler(worker);

        let event = mydia_rs_pubsub::recv_with_timeout(&mut rx, std::time::Duration::from_secs(1))
            .await
            .expect("recv timeout")
            .expect("event landed on jobs:status");
        assert_eq!(event.payload["kind"], "start");
        assert_eq!(event.payload["worker_id"], "library_scanner");
    }

    #[tokio::test]
    async fn handler_maps_engage_to_kind_engage() {
        let bus = Pubsub::new();
        let mut rx = bus.subscribe(topics::JOBS_STATUS);
        let handler = make_handler(bus.clone());

        let task_id = apalis::prelude::TaskId::new();
        let worker = Worker::new(WorkerId::new("foo"), ApalisEvent::Engage(task_id));
        handler(worker);

        let event = mydia_rs_pubsub::recv_with_timeout(&mut rx, std::time::Duration::from_secs(1))
            .await
            .expect("recv timeout")
            .expect("event landed on jobs:status");
        assert_eq!(event.payload["kind"], "engage");
        assert!(event.payload["payload"]["task_id"].is_string());
    }
}
