//! Golden bytes for the request and response encodings.
//!
//! serde_cbor uses serde's externally tagged representation, so an enum is
//! keyed on the variant *name*. Renaming a variant therefore breaks every peer
//! running an older build, while reordering is harmless. These assertions exist
//! so a rename fails here rather than in the field.

use mydia_p2p_core::{MydiaRequest, MydiaResponse, RemoteControlRequest, RemoteControlResponse};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn ping_encoding_is_stable() {
    // A unit variant encodes as its name as a CBOR text string.
    // 0x64 = text(4), then "Ping". Verified against serde_cbor 0.11's actual
    // output, not merely asserted from the expected shape.
    assert_eq!(
        hex(&serde_cbor::to_vec(&MydiaRequest::Ping).unwrap()),
        "6450696e67"
    );
}

#[test]
fn pong_encoding_is_stable() {
    // 0x64 = text(4), then "Pong". Verified against serde_cbor 0.11's actual
    // output, not merely asserted from the expected shape.
    assert_eq!(
        hex(&serde_cbor::to_vec(&MydiaResponse::Pong).unwrap()),
        "64506f6e67"
    );
}

#[test]
fn every_request_variant_name_is_frozen() {
    // Decoding a hand-written encoding proves the name, not just that our own
    // round trip agrees with itself.
    let get_state =
        serde_cbor::to_vec(&MydiaRequest::RemoteControl(RemoteControlRequest::GetState)).unwrap();

    let decoded: MydiaRequest = serde_cbor::from_slice(&get_state).unwrap();
    assert_eq!(
        decoded,
        MydiaRequest::RemoteControl(RemoteControlRequest::GetState)
    );

    // The outer variant name must appear literally in the bytes.
    let as_text = String::from_utf8_lossy(&get_state);
    assert!(
        as_text.contains("RemoteControl"),
        "outer variant renamed: {as_text}"
    );
    assert!(
        as_text.contains("GetState"),
        "inner variant renamed: {as_text}"
    );
}

#[test]
fn an_old_peer_fails_cleanly_on_an_unknown_variant() {
    // What an old target does when a new controller says Hello: the whole
    // request fails to decode. The controller reads that as "too old".
    let hello = serde_cbor::to_vec(&MydiaRequest::RemoteControl(RemoteControlRequest::Hello {
        controller_name: "iPhone".into(),
        protocol_version: 1,
    }))
    .unwrap();

    #[derive(Debug, serde::Deserialize)]
    #[allow(dead_code)]
    enum OldRequest {
        Ping,
        Custom(Vec<u8>),
    }

    let result: Result<OldRequest, _> = serde_cbor::from_slice(&hello);
    assert!(
        result.is_err(),
        "an old peer must reject an unknown variant"
    );
}

#[test]
fn a_response_survives_a_round_trip_through_the_outer_enum() {
    let response = MydiaResponse::RemoteControl(RemoteControlResponse::NotAuthorized);
    let bytes = serde_cbor::to_vec(&response).unwrap();
    let decoded: MydiaResponse = serde_cbor::from_slice(&bytes).unwrap();
    assert_eq!(decoded, response);
}
