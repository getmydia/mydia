//! Remote access GraphQL types — ports of `common_types.ex:138-222`
//! (`media_token`, `claim_code`, `remote_access_status`).

use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MediaToken")]
pub struct MediaTokenObject {
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub permissions: Vec<String>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ClaimCode")]
pub struct ClaimCodeObject {
    pub code: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "RemoteAccessStatus")]
pub struct RemoteAccessStatus {
    pub enabled: bool,
    pub endpoint_addr: Option<String>,
    pub connected_peers: i32,
}
