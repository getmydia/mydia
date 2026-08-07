//! Task spawning that works on both native and wasm targets.
//!
//! Each `Host` used to spawn its own OS thread with its own tokio `Runtime`.
//! A browser has neither, so the spawn point lives here instead. `n0-future`
//! is iroh's own abstraction for this split and carries the conditional
//! `Send` bound, which matters because iroh's browser futures are not `Send`.

pub use n0_future::task::spawn;

/// Drive a future to completion from a synchronous caller.
///
/// Native only. The Rustler NIF calls this from Erlang scheduler threads,
/// which are never tokio runtime threads, so the usual "block_on inside a
/// runtime panics" hazard does not apply. There is no wasm equivalent and
/// there cannot be one: a browser cannot block its only thread.
#[cfg(not(target_arch = "wasm32"))]
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    use std::sync::OnceLock;
    use tokio::runtime::Runtime;

    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    RUNTIME
        .get_or_init(|| {
            Runtime::new().expect("failed to create the mydia_p2p_core tokio runtime")
        })
        .block_on(future)
}
