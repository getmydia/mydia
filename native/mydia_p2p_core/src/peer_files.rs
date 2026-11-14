//! Wire types for sharing a player's Files libraries with its paired peers.
//!
//! Like `peer_sync`, this is free of iroh and of any I/O. The transport is
//! `MydiaRequest::PeerFiles`; file bytes do not travel here but ride
//! `HlsStream` under a session id starting with `PEER_FILE_SESSION_PREFIX`.

/// Prefix of the `HlsRequest::session_id` a peer uses to read file bytes, so
/// the responding player can tell a file read from an HLS session.
pub const PEER_FILE_SESSION_PREFIX: &str = "peerfile:";

/// Soft cap on the encoded size of one `IndexPage`. The responder stops adding
/// records once a page reaches it, so a page always fits comfortably in one
/// request/response exchange.
pub const PEER_FILES_PAGE_BUDGET: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WireSharedAccount {
    pub account_id: String,
    pub kind: String,
    pub name: String,
    pub dedupe_key: Option<String>,
    pub revision: u64,
}

/// One page of an account's index. Each element is a single record exactly as
/// Dart encodes it (UTF-8 JSON of the record's `toMap()`), so Rust never has
/// to mirror the Dart record shapes.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WireIndexPage {
    pub roots: Vec<Vec<u8>>,
    pub files: Vec<Vec<u8>>,
    pub groups: Vec<Vec<u8>>,
    pub movies: Vec<Vec<u8>>,
    pub shows: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerFilesRequest {
    Manifest {
        auth_proof: String,
    },
    IndexPage {
        auth_proof: String,
        account_id: String,
        revision: u64,
        cursor: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerFilesResponse {
    Manifest {
        accounts: Vec<WireSharedAccount>,
    },
    IndexPage {
        page: WireIndexPage,
        next_cursor: Option<String>,
    },
    /// The index changed since the revision the requester named, so it must
    /// restart from the manifest.
    StaleRevision,
    NotAuthorized,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account() -> WireSharedAccount {
        WireSharedAccount {
            account_id: "acct-1".into(),
            kind: "smb".into(),
            name: "Basement NAS".into(),
            dedupe_key: None,
            revision: 3,
        }
    }

    #[test]
    fn manifest_round_trips_cbor() {
        let request = PeerFilesRequest::Manifest {
            auth_proof: "proof".into(),
        };
        let bytes = serde_cbor::to_vec(&request).expect("serialize request");
        let decoded: PeerFilesRequest = serde_cbor::from_slice(&bytes).expect("deserialize");
        assert_eq!(decoded, request);

        let response = PeerFilesResponse::Manifest {
            accounts: vec![account()],
        };
        let bytes = serde_cbor::to_vec(&response).expect("serialize response");
        let decoded: PeerFilesResponse = serde_cbor::from_slice(&bytes).expect("deserialize");
        assert_eq!(decoded, response);
    }

    #[test]
    fn index_page_round_trips_cbor() {
        let request = PeerFilesRequest::IndexPage {
            auth_proof: "proof".into(),
            account_id: "acct-1".into(),
            revision: 3,
            cursor: Some("files:200".into()),
        };
        let bytes = serde_cbor::to_vec(&request).expect("serialize request");
        let decoded: PeerFilesRequest = serde_cbor::from_slice(&bytes).expect("deserialize");
        assert_eq!(decoded, request);

        let response = PeerFilesResponse::IndexPage {
            page: WireIndexPage {
                roots: vec![vec![1, 2]],
                files: vec![vec![3], vec![4, 5, 6]],
                groups: vec![],
                movies: vec![vec![7]],
                shows: vec![vec![8]],
            },
            next_cursor: Some("files:400".into()),
        };
        let bytes = serde_cbor::to_vec(&response).expect("serialize response");
        let decoded: PeerFilesResponse = serde_cbor::from_slice(&bytes).expect("deserialize");
        assert_eq!(decoded, response);
    }

    #[test]
    fn stale_and_not_authorized_round_trip() {
        for response in [
            PeerFilesResponse::StaleRevision,
            PeerFilesResponse::NotAuthorized,
        ] {
            let bytes = serde_cbor::to_vec(&response).expect("serialize");
            let decoded: PeerFilesResponse = serde_cbor::from_slice(&bytes).expect("deserialize");
            assert_eq!(decoded, response);
        }
    }
}
