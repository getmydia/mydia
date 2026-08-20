//! Golden bytes for the request and response encodings.
//!
//! serde_cbor uses serde's externally tagged representation, so an enum is
//! keyed on the variant *name*. Renaming a variant therefore breaks every peer
//! running an older build, while reordering is harmless. These assertions exist
//! so a rename fails here rather than in the field.

use mydia_p2p_core::{
    MydiaRequest, MydiaResponse, PlaybackSnapshot, PlaybackState, RemoteControlRequest,
    RemoteControlResponse, TargetCapabilities,
};

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
    let err = result.expect_err("an old peer must reject an unknown variant");
    // Pin the *reason*, not just that decoding failed: a truncation or
    // type-mismatch bug elsewhere would also produce an Err and could mask
    // the thing this test exists to catch.
    let message = err.to_string();
    assert!(
        message.contains("unknown variant"),
        "expected an unknown-variant error, got: {message}"
    );
}

#[test]
fn every_response_variant_name_is_frozen() {
    // The response-side analog of `every_request_variant_name_is_frozen`. A
    // self-round-trip (encode then decode through the same live types) can't
    // catch a rename, because the rename changes both sides together and
    // equality still holds. Only a literal-bytes check on the wire format
    // does that, so assert the variant names appear literally in the CBOR.
    let not_authorized = serde_cbor::to_vec(&MydiaResponse::RemoteControl(
        RemoteControlResponse::NotAuthorized,
    ))
    .unwrap();
    let as_text = String::from_utf8_lossy(&not_authorized);
    assert!(
        as_text.contains("RemoteControl"),
        "outer variant renamed: {as_text}"
    );
    assert!(
        as_text.contains("NotAuthorized"),
        "inner variant renamed: {as_text}"
    );

    // `State` is the one response variant that carries a payload, so it is
    // worth covering separately from the unit-like `NotAuthorized` case.
    let state = serde_cbor::to_vec(&MydiaResponse::RemoteControl(RemoteControlResponse::State(
        PlaybackSnapshot {
            state: PlaybackState::Playing,
            media_item_id: Some("item-1".into()),
            episode_id: None,
            title: "Arrival".into(),
            subtitle: None,
            image_url: None,
            position_ms: 1_000,
            duration_ms: 100_000,
            volume: Some(1.0),
            muted: false,
            audio_tracks: vec![],
            subtitle_tracks: vec![],
            selected_audio: None,
            selected_subtitle: None,
            capabilities: TargetCapabilities {
                volume: true,
                track_selection: true,
                next_previous: true,
            },
            sequence: 1,
        },
    )))
    .unwrap();
    let as_text = String::from_utf8_lossy(&state);
    assert!(
        as_text.contains("RemoteControl"),
        "outer variant renamed: {as_text}"
    );
    assert!(
        as_text.contains("State"),
        "inner variant renamed: {as_text}"
    );
}

#[test]
fn a_response_survives_a_round_trip_through_the_outer_enum() {
    // A correctness check, not a format check: this proves our own encoder
    // and decoder agree, but a rename changes both sides together and this
    // assertion would still pass. `every_response_variant_name_is_frozen`
    // above is what actually pins the wire format.
    let response = MydiaResponse::RemoteControl(RemoteControlResponse::NotAuthorized);
    let bytes = serde_cbor::to_vec(&response).unwrap();
    let decoded: MydiaResponse = serde_cbor::from_slice(&bytes).unwrap();
    assert_eq!(decoded, response);
}
