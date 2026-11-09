//! Wire types for peer-to-peer watch-state synchronization.
//!
//! Deliberately free of iroh and of any I/O, so it unit-tests in isolation and
//! compiles for wasm unchanged. The transport is `MydiaRequest::PeerSync`.

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WirePeerMember {
    pub node_id: String,
    pub device_name: String,
    pub platform: String,
    pub endpoint_addr_json: Option<String>,
    pub updated_at_ms: i64,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WireWatchRecord {
    pub key: String,
    pub watched: bool,
    pub position_seconds: Option<i64>,
    pub duration_seconds: Option<i64>,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WirePinRecord {
    pub key: String,
    pub group_key: String,
    pub is_show: bool,
    pub tmdb_id: Option<i64>,
    pub pinned: bool,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerSyncRequest {
    Pair {
        claim_code: String,
        device_name: String,
        platform: String,
        endpoint_addr_json: Option<String>,
    },
    Sync {
        auth_proof: String,
        sender_endpoint_addr_json: Option<String>,
        roster: Vec<WirePeerMember>,
        since_landed_ms: i64,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerSyncResponse {
    Paired {
        group_secret_base64: String,
        roster: Vec<WirePeerMember>,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
    },
    PairRejected {
        reason: String,
    },
    SyncAck {
        roster: Vec<WirePeerMember>,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
        peer_now_ms: i64,
    },
    NotAuthorized,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_request_round_trips_cbor() {
        let request = PeerSyncRequest::Pair {
            claim_code: "123456".into(),
            device_name: "Pixel 9".into(),
            platform: "android".into(),
            endpoint_addr_json: Some("{\"node_id\":\"abc\"}".into()),
        };
        let bytes = serde_cbor::to_vec(&request).expect("serialize pair request");
        let decoded: PeerSyncRequest =
            serde_cbor::from_slice(&bytes).expect("deserialize pair request");
        assert_eq!(decoded, request);
    }

    #[test]
    fn sync_request_round_trips_cbor() {
        let request = PeerSyncRequest::Sync {
            auth_proof: "proof_abc".into(),
            sender_endpoint_addr_json: None,
            roster: vec![WirePeerMember {
                node_id: "node_1".into(),
                device_name: "MacBook Pro".into(),
                platform: "macos".into(),
                endpoint_addr_json: None,
                updated_at_ms: 1000,
                revoked: false,
            }],
            since_landed_ms: 500,
            watch_records: vec![WireWatchRecord {
                key: "tmdb:movie:603".into(),
                watched: true,
                position_seconds: Some(3600),
                duration_seconds: Some(7200),
                updated_at_ms: 600,
            }],
            pin_records: vec![WirePinRecord {
                key: "pin:m:matrix:1999".into(),
                group_key: "matrix:1999".into(),
                is_show: false,
                tmdb_id: Some(603),
                pinned: true,
                updated_at_ms: 700,
            }],
        };
        let bytes = serde_cbor::to_vec(&request).expect("serialize sync request");
        let decoded: PeerSyncRequest =
            serde_cbor::from_slice(&bytes).expect("deserialize sync request");
        assert_eq!(decoded, request);
    }

    #[test]
    fn paired_response_round_trips_cbor() {
        let response = PeerSyncResponse::Paired {
            group_secret_base64: "c2VjcmV0".into(),
            roster: vec![WirePeerMember {
                node_id: "node_2".into(),
                device_name: "Living Room TV".into(),
                platform: "android".into(),
                endpoint_addr_json: None,
                updated_at_ms: 2000,
                revoked: false,
            }],
            watch_records: vec![WireWatchRecord {
                key: "tmdb:episode:123:1:1".into(),
                watched: false,
                position_seconds: Some(120),
                duration_seconds: Some(2400),
                updated_at_ms: 2100,
            }],
            pin_records: vec![],
        };
        let bytes = serde_cbor::to_vec(&response).expect("serialize paired response");
        let decoded: PeerSyncResponse =
            serde_cbor::from_slice(&bytes).expect("deserialize paired response");
        assert_eq!(decoded, response);
    }

    #[test]
    fn pair_rejected_response_round_trips_cbor() {
        let response = PeerSyncResponse::PairRejected {
            reason: "invalid_claim_code".into(),
        };
        let bytes = serde_cbor::to_vec(&response).expect("serialize pair rejected response");
        let decoded: PeerSyncResponse =
            serde_cbor::from_slice(&bytes).expect("deserialize pair rejected response");
        assert_eq!(decoded, response);
    }

    #[test]
    fn sync_ack_response_round_trips_cbor() {
        let response = PeerSyncResponse::SyncAck {
            roster: vec![],
            watch_records: vec![],
            pin_records: vec![],
            peer_now_ms: 9999,
        };
        let bytes = serde_cbor::to_vec(&response).expect("serialize sync ack response");
        let decoded: PeerSyncResponse =
            serde_cbor::from_slice(&bytes).expect("deserialize sync ack response");
        assert_eq!(decoded, response);
    }

    #[test]
    fn not_authorized_response_round_trips_cbor() {
        let response = PeerSyncResponse::NotAuthorized;
        let bytes = serde_cbor::to_vec(&response).expect("serialize not authorized response");
        let decoded: PeerSyncResponse =
            serde_cbor::from_slice(&bytes).expect("deserialize not authorized response");
        assert_eq!(decoded, response);
    }
}
