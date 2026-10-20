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

// An attribute on the `wit_bindgen::generate!` invocation does not reach the
// code it expands to, so this one lint is allowed crate-wide. The crate holds
// no hand-written `Vec::from_raw_parts`, only the generated list lowerings.
#![allow(
    clippy::same_length_and_capacity,
    reason = "fires in wit-bindgen generated list lowering, which cannot be edited or targeted"
)]

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
pub use exports::mydia::plugin::handler::Guest;
pub use exports::mydia::plugin::page::Guest as PageGuest;
pub use mydia::plugin::host;
pub use mydia::plugin::types;

/// The `#[mydia_plugin_sdk::plugin]` attribute macro: write a plain typed handler, get a
/// component. See `mydia-plugin-macros`.
pub use mydia_plugin_macros::plugin;
