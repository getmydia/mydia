//! Host-runtime test fixture (U3) — see Cargo.toml for the behavior table.
//!
//! One component, many behaviors, selected by the event type. Authored on the
//! published SDK + `#[mydia_plugin_sdk::plugin]` macro, so it also smoke-tests that the
//! macro expands to a valid component export.

use std::sync::atomic::{AtomicBool, Ordering};

use mydia_plugin_sdk::types::Event;

// Reset to `false` for every fresh instance. With a fresh store + instance per
// invocation (KTD9), the first observation in each call is always `true`; a
// reused instance would flip it to `false` on the second call.
static SEEN: AtomicBool = AtomicBool::new(false);

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    match evt.event.as_str() {
        // Probe for ambient host capability. WasiP2Options leaves env empty and
        // stdio uninherited, so a host env var the process surely has (PATH)
        // must NOT be visible to the guest — proving the sandbox does not leak
        // host state in. (Filesystem syscalls can't be probed here: wasmtime-wasi
        // panics on a sync block_on, so structural denial via no-preopens is
        // relied on instead.)
        "probe-env" => {
            let denied = std::env::var("PATH").is_err();
            Ok(format!("{{\"env_denied\":{}}}", denied))
        }

        // Surface as a host :trap. Use process::abort (an immediate unreachable)
        // rather than panic! so no stderr write precedes the trap — a guest that
        // prints to the denied stderr on its way down trips wasmtime-wasi's sync
        // block_on panic and times out instead of trapping cleanly.
        "trap" => std::process::abort(),

        // Return the WIT `result` error variant, surfacing as a host
        // :guest_error (distinct from a trap).
        "error" => Err("intentional guest error".to_string()),

        // Default / "ok": fresh-store isolation probe.
        _ => {
            let first = !SEEN.swap(true, Ordering::SeqCst);
            Ok(format!("{{\"first\":{}}}", first))
        }
    }
}
