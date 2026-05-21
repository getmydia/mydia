//! In-process pubsub backed by `tokio::sync::broadcast`, one sender
//! per topic.
//!
//! Phoenix uses `Phoenix.PubSub` with the local-process adapter — every
//! event is broadcast inside one BEAM node, and subscribers select by
//! topic string. mydia-rs mirrors that shape with a dashmap of
//! `broadcast::Sender<Event>`s, one entry per topic.
//!
//! Per-topic senders (rather than one shared sender with topic-tagged
//! messages) give each topic its own backpressure window. A busy
//! `library_scanner` topic dropping messages does not affect a quiet
//! `device_status:<user>` subscriber.
//!
//! ## Scope
//!
//! This crate ships in U11 (graphql playback mutations need somewhere
//! to publish) and U12 (subscriptions need somewhere to subscribe). The
//! load-bearing surface — canonical topic constants, worker fan-out
//! integration, structured event types — lands in U15. The shape here
//! is deliberately minimal so U15 can add structure without rewriting
//! call sites.

use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use serde::Serialize;
use tokio::sync::broadcast;
use tokio::time::error::Elapsed;

/// Default channel buffer per topic. Subscribers further behind than
/// this number of messages receive a `broadcast::error::RecvError::Lagged`
/// and skip ahead. U15 may tune per-topic when the canonical topic
/// registry lands.
pub const DEFAULT_CHANNEL_CAPACITY: usize = 64;

/// An event published on the bus. Carries a JSON payload because the
/// graphql crate (and later jobs / workers) serializes domain values
/// once at publish time and decoders pick what they need.
#[derive(Debug, Clone)]
pub struct Event {
    pub payload: serde_json::Value,
}

impl Event {
    /// Build an event from any `Serialize` value. Used by publishers
    /// that want a typed write site and don't care about the wire
    /// representation downstream.
    pub fn from_serializable<T: Serialize>(value: &T) -> Result<Self, serde_json::Error> {
        Ok(Self {
            payload: serde_json::to_value(value)?,
        })
    }

    /// Convenience: build an event wrapping a `serde_json::Value`
    /// directly. The resolver-side broadcasts use this when the
    /// payload is already shaped JSON.
    pub fn from_json(payload: serde_json::Value) -> Self {
        Self { payload }
    }
}

/// Handle to the in-process pubsub. Cheap to clone (one `Arc` per
/// clone). Shared across the graphql resolver context, axum
/// extractors, and (in later units) apalis workers.
#[derive(Clone)]
pub struct Pubsub {
    inner: Arc<Inner>,
}

struct Inner {
    capacity: usize,
    senders: DashMap<String, broadcast::Sender<Event>>,
}

impl Pubsub {
    /// Build with the default per-topic capacity.
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_CHANNEL_CAPACITY)
    }

    /// Build with a custom per-topic broadcast capacity. Useful in
    /// tests where small buffers exercise overflow semantics.
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            inner: Arc::new(Inner {
                capacity,
                senders: DashMap::new(),
            }),
        }
    }

    /// Publish `event` on `topic`. Returns the number of currently-
    /// connected subscribers that received the message — `0` for a
    /// topic with no subscribers, which is a no-op (matching
    /// `Phoenix.PubSub.broadcast/3`'s behavior).
    pub fn publish(&self, topic: &str, event: Event) -> usize {
        // Don't create a sender on publish if nobody has subscribed
        // yet — fan-out is "0 receivers" in that case and creating an
        // entry would leak memory for topics that are never read
        // (per-media-item progress topics are a worst-case here).
        match self.inner.senders.get(topic) {
            Some(sender) => sender.send(event).unwrap_or(0),
            None => 0,
        }
    }

    /// Subscribe to `topic`. Creates the underlying broadcast channel
    /// if it doesn't exist yet. The returned `Receiver` lags subscribers
    /// that fall further behind than the channel capacity.
    pub fn subscribe(&self, topic: &str) -> broadcast::Receiver<Event> {
        let entry = self
            .inner
            .senders
            .entry(topic.to_owned())
            .or_insert_with(|| {
                let (tx, _rx) = broadcast::channel(self.inner.capacity);
                tx
            });
        entry.value().subscribe()
    }

    /// Snapshot of the topics that currently have a sender (live
    /// subscribers exist or have existed). Useful for tests and the
    /// future admin debug surface; not load-bearing.
    pub fn topics(&self) -> Vec<String> {
        self.inner
            .senders
            .iter()
            .map(|entry| entry.key().clone())
            .collect()
    }

    /// Drop the broadcast channel for `topic` if no subscribers remain.
    /// `Pubsub` doesn't currently garbage-collect; U15 may add an idle-
    /// topic reaper, but this helper covers the test-side cleanup case.
    pub fn drop_topic_if_idle(&self, topic: &str) -> bool {
        let mut removed = false;
        self.inner.senders.remove_if(topic, |_, sender| {
            if sender.receiver_count() == 0 {
                removed = true;
                true
            } else {
                false
            }
        });
        removed
    }
}

impl Default for Pubsub {
    fn default() -> Self {
        Self::new()
    }
}

/// Convenience extension for tests: receive with a timeout, returning
/// `None` when the timeout elapses. Not on `Pubsub` itself — operates
/// on a `Receiver` you already hold.
pub async fn recv_with_timeout(
    rx: &mut broadcast::Receiver<Event>,
    timeout: Duration,
) -> Result<Option<Event>, Elapsed> {
    match tokio::time::timeout(timeout, rx.recv()).await {
        Ok(Ok(event)) => Ok(Some(event)),
        Ok(Err(_)) => Ok(None),
        Err(elapsed) => Err(elapsed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn publish_to_no_subscriber_is_noop() {
        let bus = Pubsub::new();
        let count = bus.publish("library_scanner", Event::from_json(serde_json::json!({})));
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn subscriber_receives_published_event() {
        let bus = Pubsub::new();
        let mut rx = bus.subscribe("progress:abc");
        let count = bus.publish(
            "progress:abc",
            Event::from_json(serde_json::json!({"position": 42})),
        );
        assert_eq!(count, 1);
        let event = rx.recv().await.expect("recv");
        assert_eq!(event.payload["position"], 42);
    }

    #[tokio::test]
    async fn topics_are_isolated() {
        let bus = Pubsub::new();
        let mut rx_a = bus.subscribe("topic:a");
        let mut rx_b = bus.subscribe("topic:b");
        bus.publish("topic:a", Event::from_json(serde_json::json!({"v": "a"})));
        let received_a = rx_a.recv().await.unwrap();
        assert_eq!(received_a.payload["v"], "a");
        // topic:b should still be empty.
        let timeout_result = recv_with_timeout(&mut rx_b, Duration::from_millis(20)).await;
        assert!(timeout_result.is_err());
    }

    #[tokio::test]
    async fn drop_topic_if_idle_removes_only_empty_topics() {
        let bus = Pubsub::new();
        let _live = bus.subscribe("live");
        // create an idle topic by subscribing then dropping
        {
            let _rx = bus.subscribe("idle");
        }
        // Drop should remove the idle one
        assert!(bus.drop_topic_if_idle("idle"));
        // But not the live one
        assert!(!bus.drop_topic_if_idle("live"));
        assert!(bus.topics().contains(&"live".to_owned()));
    }
}
