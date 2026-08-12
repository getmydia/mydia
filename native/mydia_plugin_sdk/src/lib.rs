//! Mydia plugin authoring SDK.
//!
//! Typed WASM component-model bindings generated from `wit/plugin.wit` — the
//! single source of truth shared with the Elixir host — plus (U6) the
//! `#[mydia_plugin_sdk::plugin]` attribute macro that lets an author write a plain typed
//! event handler.
//!
//! A plugin crate depends on this SDK, implements the [`exports::mydia::plugin::handler::Guest`]
//! trait (the U6 macro generates this), and calls the re-exported export macro to
//! emit the component. Host capabilities are reached through the generated
//! [`mydia::plugin::host`] module (`http_request`, `data_read`).

wit_bindgen::generate!({
    world: "plugin",
    // The SDK is a library; downstream plugin crates invoke the export macro it
    // re-exports, so generate it as `pub` with this crate as the bindings module
    // and a stable name the #[mydia_plugin_sdk::plugin] proc-macro can call.
    pub_export_macro: true,
    export_macro_name: "export_plugin",
    default_bindings_module: "mydia_plugin_sdk",
});

// Re-export the generated host-capability bindings and shared types so plugin
// authors reach them through a stable `mydia_plugin_sdk::...` path rather than a
// generated module name.
pub mod host {
    //! Host-implemented capabilities imported by plugin guests.
    pub use super::mydia::plugin::host::*;

    /// Register or update a connection. Requires `surfaces:write: ["connections"]`.
    pub fn connection_upsert(
        draft: &super::types::ConnectionDraft,
    ) -> Result<super::types::Connection, super::types::HostError> {
        super::mydia::plugin::host::connection_upsert(draft)
    }
}

pub use exports::mydia::plugin::handler::Guest;
pub use mydia::plugin::types;

// New 1.3.0 connect / connection-draft types (also available on `types::`).
pub use mydia::plugin::types::{
    ConnectChoice, ConnectDone, ConnectField, ConnectPending, ConnectPrompt, ConnectRequest,
    ConnectResponse, ConnectionDraft, ConnectionScope,
};

/// The `#[mydia_plugin_sdk::plugin]` attribute macro: write a plain typed handler, get a
/// component. See `mydia-plugin-macros`.
pub use mydia_plugin_macros::plugin;
