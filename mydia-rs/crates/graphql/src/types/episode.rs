//! Episode — port of `lib/mydia_web/schema/media_types.ex:236-300`.
//!
//! Episodes carry a parent `media_item_id` for the show they belong
//! to; the parent show object surfaces in U10.c via the Node
//! interface and the `show` field resolver.

use async_graphql::{SimpleObject, ID};
use chrono::NaiveDate;

use crate::node_id::{NodeId, NodeRef};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Episode")]
pub struct Episode {
    /// Encoded `episode:<uuid>` form.
    pub id: ID,
    /// Plain UUID of the parent media item (the show). Used by U10.c
    /// to wire the `show` and parent/ancestors resolvers.
    pub media_item_id: String,
    pub season_number: i32,
    pub episode_number: i32,
    pub title: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub monitored: bool,
}

impl Episode {
    pub fn from_row(row: &mydia_rs_models::Episode) -> Self {
        Self {
            id: NodeId::Episode(NodeRef::Str(row.id.0.to_string()))
                .encode()
                .into(),
            media_item_id: row.media_item_id.0.to_string(),
            season_number: row.season_number.unwrap_or(0),
            episode_number: row.episode_number.unwrap_or(0),
            title: row.title.clone(),
            air_date: row.air_date,
            monitored: row.monitored,
        }
    }
}
