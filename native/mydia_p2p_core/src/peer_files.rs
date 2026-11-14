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
///
/// Each record is encoded as a CBOR byte string. serde's default for
/// `Vec<u8>` is an array of integers, which costs two bytes for most JSON
/// characters and so doubles a page past `PEER_FILES_PAGE_BUDGET`, whose
/// accounting in Dart assumes byte-string framing.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WireIndexPage {
    #[serde(with = "byte_strings")]
    pub roots: Vec<Vec<u8>>,
    #[serde(with = "byte_strings")]
    pub files: Vec<Vec<u8>>,
    #[serde(with = "byte_strings")]
    pub groups: Vec<Vec<u8>>,
    #[serde(with = "byte_strings")]
    pub movies: Vec<Vec<u8>>,
    #[serde(with = "byte_strings")]
    pub shows: Vec<Vec<u8>>,
}

/// A list of records, each as a byte string. Decoding also takes the
/// integer-array form, which `serde_bytes::ByteBuf` accepts.
mod byte_strings {
    use serde::{Deserialize, Deserializer, Serializer};
    use serde_bytes::{ByteBuf, Bytes};

    pub fn serialize<S: Serializer>(records: &[Vec<u8>], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(records.iter().map(|record| Bytes::new(record)))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Vec<Vec<u8>>, D::Error> {
        let records = Vec::<ByteBuf>::deserialize(deserializer)?;
        Ok(records.into_iter().map(ByteBuf::into_vec).collect())
    }
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
    /// The request failed a check: a bad proof, a node the roster does not
    /// hold, or a responder whose group secret did not load. Proves nothing
    /// about the requester's membership.
    NotAuthorized,
    /// The responder's roster marks the requester revoked. A revoked device
    /// cannot sync, so this is how it learns it was removed. Appended last so
    /// the earlier variants keep their encoding.
    Revoked,
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
            PeerFilesResponse::Revoked,
        ] {
            let bytes = serde_cbor::to_vec(&response).expect("serialize");
            let decoded: PeerFilesResponse = serde_cbor::from_slice(&bytes).expect("deserialize");
            assert_eq!(decoded, response);
        }
    }

    /// A near-budget page, encoded as the whole transport response exactly as
    /// the core sends it, must stay near `PEER_FILES_PAGE_BUDGET` and well
    /// under the response cap the requester reads with.
    #[test]
    fn near_budget_page_fits_the_transport_response() {
        const RECORD_OVERHEAD: usize = 9;
        const FRAMING_SLACK: usize = 1024;
        // The Dart pager charges each record its byte length plus 9 (the
        // widest CBOR byte string header). Fill the five lists round-robin
        // with realistic JSON-sized records, a few large ones among them,
        // until the same accounting reaches the budget.
        let mut page = WireIndexPage::default();
        let mut charged = 0usize;
        let mut n = 0usize;
        loop {
            let len = match n % 50 {
                0 => 70_000,
                1 => 20_000,
                m => 200 + (m * 37) % 600,
            };
            if charged + len + RECORD_OVERHEAD > PEER_FILES_PAGE_BUDGET {
                break;
            }
            charged += len + RECORD_OVERHEAD;
            let record = vec![b'a'; len];
            match n % 5 {
                0 => page.roots.push(record),
                1 => page.files.push(record),
                2 => page.groups.push(record),
                3 => page.movies.push(record),
                _ => page.shows.push(record),
            }
            n += 1;
        }
        assert!(
            PEER_FILES_PAGE_BUDGET - charged < 70_000 + RECORD_OVERHEAD,
            "page should be filled to within one record of the budget"
        );

        let response = crate::MydiaResponse::PeerFiles(PeerFilesResponse::IndexPage {
            page,
            next_cursor: Some("files:123456".into()),
        });
        let encoded = serde_cbor::to_vec(&response).expect("serialize response");

        // Framing outside the records: the MydiaResponse and PeerFilesResponse
        // variant keys, the page and next_cursor keys, five list names and
        // headers, and the cursor, all under 200 bytes. Real byte string
        // headers are 1 to 5 bytes for records under 4 GiB, so they come in
        // under the 9 charged per record. 1 KiB of slack is generous.
        println!(
            "encoded page: {} bytes, budget {}",
            encoded.len(),
            PEER_FILES_PAGE_BUDGET
        );
        assert!(
            encoded.len() <= PEER_FILES_PAGE_BUDGET + FRAMING_SLACK,
            "encoded {} bytes exceeds budget plus slack",
            encoded.len()
        );
        assert!(encoded.len() < crate::MAX_RESPONSE_BYTES);
        let decoded: crate::MydiaResponse =
            serde_cbor::from_slice(&encoded).expect("deserialize response");
        assert!(matches!(
            decoded,
            crate::MydiaResponse::PeerFiles(PeerFilesResponse::IndexPage { .. })
        ));
    }
}
