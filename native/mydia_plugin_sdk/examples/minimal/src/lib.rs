//! Minimal Mydia plugin — the scaffold starter and the SDK smoke test.
//!
//! An author writes one plain function. `#[mydia_plugin_sdk::plugin]` implements
//! the generated `Guest` trait and emits the component export. The handler is
//! ordinary Rust, so it can be unit-tested directly (see the test below) with no
//! wasm build or running host.

use mydia_plugin_sdk::types::Event;

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    Ok(format!("{{\"handled\":\"{}\"}}", evt.event))
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_plugin_sdk::types::Event;

    #[test]
    fn handles_event_without_host() {
        let evt = Event {
            event: "media_item.added".into(),
            category: None,
            severity: None,
            actor_type: None,
            actor_id: None,
            resource_type: None,
            resource_id: None,
            metadata_json: "{}".into(),
        };

        assert_eq!(on_event(evt), Ok("{\"handled\":\"media_item.added\"}".into()));
    }

    #[test]
    fn setup_defaults_to_an_error() {
        use mydia_plugin_sdk::types::SetupRequest;
        use mydia_plugin_sdk::Guest;

        let req = SetupRequest {
            step: "start".into(),
            input_json: "{}".into(),
            state_json: "{}".into(),
            config_json: "{}".into(),
        };

        assert_eq!(
            super::__MydiaPluginImpl::setup(req).err(),
            Some("setup not implemented by this plugin".to_string())
        );
    }
}
