use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    ConnectDone, ConnectPending, ConnectRequest, ConnectResponse, ConnectionDraft, Event,
    OutboundRequest,
};

#[mydia_plugin_sdk::plugin(on_connect = on_connect)]
fn on_event(_evt: Event) -> Result<String, String> {
    // Exercise the relative-URL path against every instance connection.
    let conns = host::connections_list().map_err(|e| format!("{e:?}"))?;
    let mut hits = 0;

    for c in conns {
        let resp = host::connection_request(
            &c.id,
            &OutboundRequest {
                url: "/ping".into(),
                method: "GET".into(),
                headers: vec![],
                body: None,
            },
        )
        .map_err(|e| format!("{e:?}"))?;

        if resp.ok {
            hits += 1;
        }
    }

    Ok(format!("{{\"hits\":{hits}}}"))
}

fn on_connect(req: ConnectRequest) -> Result<ConnectResponse, String> {
    match req.step.as_str() {
        "start" => Ok(ConnectResponse::Pending(ConnectPending {
            message: "Enter the code".into(),
            code: Some("TEST-CODE".into()),
            verification_url: Some("https://example.test/link".into()),
            interval_ms: 10,
            state_json: "{\"seen\":1}".into(),
        })),
        "poll" => {
            host::connection_upsert(&ConnectionDraft {
                label: "Discovered".into(),
                base_urls: vec!["http://10.0.0.9:9999".into()],
                secret: "discovered-token".into(),
                auth_kind: "header".into(),
                auth_key: Some("X-Test-Token".into()),
                user_id: None,
                external_user_id: None,
                external_username: None,
            })
            .map_err(|e| format!("{e:?}"))?;

            Ok(ConnectResponse::Done(ConnectDone {
                message: "Connected".into(),
            }))
        }
        other => Err(format!("unexpected step {other}")),
    }
}
