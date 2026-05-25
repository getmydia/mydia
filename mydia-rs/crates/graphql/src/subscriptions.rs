//! GraphQL subscription root — port of
//! `lib/mydia_web/schema/subscription_types.ex`.
//!
//! Two subscriptions ship in U12:
//!
//! - `progressUpdated(nodeId)` — yields a [`crate::types::Progress`]
//!   whenever a playback mutation broadcasts on the pubsub topic
//!   **that IS the encoded global node ID**. This matches Phoenix's
//!   `topic: args.node_id` shape exactly. Subscribers pass either the
//!   encoded `movie:<uuid>` / `episode:<uuid>` form or the raw UUID;
//!   the resolver accepts both for parity with the playback mutation
//!   side (U11's `decode_id`).
//!
//! - `deviceStatusChanged(userId)` — yields a `DeviceStatusEvent` when
//!   a `device_status:<user_id>` event is broadcast. The Phoenix
//!   resolver derives the topic from `args.user_id`; mirrored here.
//!
//! Authorization filters on the receive side, NOT just at the wire.
//! Phoenix today doesn't gate subscriptions (the schema accepts any
//! subscriber); mydia-rs adds a stricter check so the client cannot
//! subscribe to another user's `deviceStatusChanged` even by guessing
//! the user ID. The filter applies to non-admin users; admins may
//! subscribe to any topic.

use async_graphql::futures_util::stream::{Stream, StreamExt};
use async_graphql::{Context, Enum, SimpleObject, Subscription, ID};
use chrono::{DateTime, Utc};
use mydia_rs_auth::role::Role;
use serde::Deserialize;
use tokio_stream::wrappers::BroadcastStream;

use crate::auth_guards::require_user;
use crate::context::{CurrentUser, GraphqlAppState};
use crate::node_id::{NodeId, NodeRef};
use crate::types::Progress;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Enum)]
#[graphql(name = "DeviceEventType")]
pub enum DeviceEventType {
    Connected,
    Disconnected,
    Revoked,
    Deleted,
}

impl DeviceEventType {
    fn from_str(value: &str) -> Self {
        // Known event variants are explicit; "disconnected" and any
        // unknown event variant fall through to `Disconnected` — graceful
        // degradation if Phoenix adds a new event during the parallel window.
        match value {
            "connected" => Self::Connected,
            "revoked" => Self::Revoked,
            "deleted" => Self::Deleted,
            _ => Self::Disconnected,
        }
    }
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Device")]
pub struct Device {
    pub id: ID,
    pub device_name: String,
    pub platform: String,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DeviceStatusEvent")]
pub struct DeviceStatusEvent {
    pub device: Device,
    pub event: DeviceEventType,
}

/// Deserialization shape for the JSON payload published on the
/// `device_status:<user_id>` topic. Mirrors what Phoenix's
/// `Absinthe.Subscription.publish/3` carries today.
#[derive(Debug, Clone, Deserialize)]
struct DeviceEventPayload {
    device: DevicePayload,
    event: String,
}

#[derive(Debug, Clone, Deserialize)]
struct DevicePayload {
    id: String,
    device_name: String,
    platform: String,
    #[serde(default)]
    last_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    revoked_at: Option<DateTime<Utc>>,
    inserted_at: DateTime<Utc>,
}

impl From<DeviceEventPayload> for DeviceStatusEvent {
    fn from(value: DeviceEventPayload) -> Self {
        Self {
            device: Device {
                id: ID(value.device.id),
                device_name: value.device.device_name,
                platform: value.device.platform,
                last_seen_at: value.device.last_seen_at,
                revoked_at: value.device.revoked_at,
                inserted_at: value.device.inserted_at,
            },
            event: DeviceEventType::from_str(&value.event),
        }
    }
}

/// Deserialization shape for the JSON payload published on the
/// per-media-item progress topic. Same shape as
/// [`crate::mutations::playback::ProgressEvent`] — kept separate so
/// the wire-side decoding stays close to the subscription resolver.
#[derive(Debug, Clone, Deserialize)]
struct ProgressPayload {
    position_seconds: i32,
    duration_seconds: i32,
    percentage: f64,
    watched: bool,
    last_watched_at: DateTime<Utc>,
}

impl From<ProgressPayload> for Progress {
    fn from(value: ProgressPayload) -> Self {
        Self {
            position_seconds: value.position_seconds,
            duration_seconds: Some(value.duration_seconds),
            percentage: Some(value.percentage),
            watched: value.watched,
            last_watched_at: Some(value.last_watched_at),
        }
    }
}

#[derive(Default)]
pub struct SubscriptionRoot;

#[Subscription]
impl SubscriptionRoot {
    /// Yield the latest `Progress` shape whenever the per-item
    /// broadcast bus fires. The `nodeId` argument is the global ID of
    /// the media item being watched — Phoenix uses `topic: args.node_id`
    /// from `subscription_types.ex:13-15`.
    ///
    /// Authorization: any authenticated user may subscribe; further
    /// per-row access gating waits on the Authorization context port
    /// in U14. The current behavior matches Phoenix (no per-item gate
    /// at the subscription layer today).
    async fn progress_updated(
        &self,
        ctx: &Context<'_>,
        node_id: ID,
    ) -> async_graphql::Result<impl Stream<Item = async_graphql::Result<Progress>>> {
        let _user = require_user(ctx)?;
        let topic = normalize_progress_topic(node_id.as_str());
        let state = ctx.data::<GraphqlAppState>()?;
        let rx = state.pubsub.subscribe(&topic);

        let stream = BroadcastStream::new(rx).filter_map(|res| async move {
            match res {
                Ok(event) => {
                    let parsed: Result<ProgressPayload, _> = serde_json::from_value(event.payload);
                    match parsed {
                        Ok(payload) => Some(Ok(Progress::from(payload))),
                        Err(err) => {
                            tracing::warn!(
                                target: "mydia_rs_graphql::subscriptions",
                                error = %err,
                                "dropping malformed progress payload"
                            );
                            None
                        }
                    }
                }
                Err(err) => {
                    tracing::warn!(
                        target: "mydia_rs_graphql::subscriptions",
                        error = %err,
                        "progress broadcast receiver lagged"
                    );
                    None
                }
            }
        });
        Ok(stream)
    }

    /// Yield device connect / disconnect / revoke events for the
    /// requested user. Authorization: the subscriber must be the user
    /// being watched, or an Admin.
    async fn device_status_changed(
        &self,
        ctx: &Context<'_>,
        user_id: ID,
    ) -> async_graphql::Result<impl Stream<Item = async_graphql::Result<DeviceStatusEvent>>> {
        let user = require_user(ctx)?;
        if !user_can_watch_device(user, user_id.as_str()) {
            return Err(async_graphql::Error::new(
                "Cannot subscribe to another user's device status",
            ));
        }
        let topic = format!("device_status:{}", user_id.as_str());
        let state = ctx.data::<GraphqlAppState>()?;
        let rx = state.pubsub.subscribe(&topic);

        let stream = BroadcastStream::new(rx).filter_map(|res| async move {
            match res {
                Ok(event) => {
                    let parsed: Result<DeviceEventPayload, _> =
                        serde_json::from_value(event.payload);
                    match parsed {
                        Ok(payload) => Some(Ok(DeviceStatusEvent::from(payload))),
                        Err(err) => {
                            tracing::warn!(
                                target: "mydia_rs_graphql::subscriptions",
                                error = %err,
                                "dropping malformed device-status payload"
                            );
                            None
                        }
                    }
                }
                Err(err) => {
                    tracing::warn!(
                        target: "mydia_rs_graphql::subscriptions",
                        error = %err,
                        "device-status broadcast receiver lagged"
                    );
                    None
                }
            }
        });
        Ok(stream)
    }
}

fn user_can_watch_device(user: &CurrentUser, target_user_id: &str) -> bool {
    if matches!(user.role, Role::Admin) {
        return true;
    }
    let target_str = target_user_id.to_owned();
    let user_id_str = user.id.to_string();
    target_str == user_id_str
}

/// Normalize the incoming subscription argument to the topic key the
/// publisher uses. The playback mutations in U11 publish on the
/// *encoded* node ID (`movie:<uuid>` / `episode:<uuid>`). The Flutter
/// player passes the encoded form by default but may also pass a raw
/// UUID — wrap it as a Movie node when so for the topic equality
/// check to land. Phoenix does no such normalization (it trusts the
/// arg); mydia-rs is stricter so subscribe-side and publish-side
/// always agree.
fn normalize_progress_topic(input: &str) -> String {
    if NodeId::decode(input).is_ok() {
        // Already encoded — use as-is.
        input.to_owned()
    } else {
        // Raw UUID/string. Default to the Movie variant — the
        // mutation side's `decode_id` accepts a raw UUID under either
        // movie or episode context, so both publish sides will emit a
        // `movie:<uuid>` topic if the caller passed a raw UUID
        // through the movie mutation, and `episode:<uuid>` if through
        // the episode mutation. Subscribers wanting both ends to
        // match should pass the encoded form.
        NodeId::Movie(NodeRef::Str(input.to_owned())).encode()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_progress_topic_passthrough_when_encoded() {
        let encoded = NodeId::Movie(NodeRef::Str("abc-uuid".to_owned())).encode();
        assert_eq!(normalize_progress_topic(&encoded), encoded);
    }

    #[test]
    fn normalize_progress_topic_wraps_raw_uuid_as_movie() {
        let normalized = normalize_progress_topic("abc-uuid");
        assert_eq!(normalized, "movie:abc-uuid");
    }
}
