//! The root subscription type.
//!
//! Both fields yield an empty stream. Slice 4 replaces them with real
//! broadcast subscriptions once there is a source of events to relay.

use async_graphql::{Context, Subscription, ID};
use futures_util::stream::{self, Stream};

use crate::types::auth::DeviceStatusEvent;
use crate::types::media::Progress;

pub struct RootSubscriptionType;

#[Subscription(name = "RootSubscriptionType")]
impl RootSubscriptionType {
    /// Subscribe to playback progress updates for a specific content item
    async fn progress_updated(
        &self,
        _ctx: &Context<'_>,
        _node_id: ID,
    ) -> impl Stream<Item = Option<Progress>> {
        stream::empty()
    }

    /// Subscribe to device status changes for a user
    async fn device_status_changed(
        &self,
        _ctx: &Context<'_>,
        _user_id: ID,
    ) -> impl Stream<Item = Option<DeviceStatusEvent>> {
        stream::empty()
    }
}
