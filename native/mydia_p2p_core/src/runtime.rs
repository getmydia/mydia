//! Task spawning that works on both native and wasm targets.
//!
//! Each `Host` used to spawn its own OS thread with its own tokio `Runtime`.
//! A browser has neither, so the spawn point lives here instead. `n0-future`
//! is iroh's own abstraction for this split and carries the conditional
//! `Send` bound, which matters because iroh's browser futures are not `Send`.

pub use n0_future::task::spawn;

#[cfg(not(target_arch = "wasm32"))]
mod imp {
    use std::sync::OnceLock;
    use tokio::runtime::{EnterGuard, Runtime};

    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    fn runtime() -> &'static Runtime {
        RUNTIME.get_or_init(|| {
            Runtime::new().expect("failed to create the mydia_p2p_core tokio runtime")
        })
    }

    /// Enter the runtime context so `spawn` has a reactor to attach to.
    ///
    /// `spawn` panics without one, and `Host::new` is called from threads
    /// that have none: BEAM schedulers through the Rustler NIF, and the Dart
    /// isolate thread through the Flutter bridge. Entering rather than
    /// blocking keeps `Host::new` portable, since a browser has no reactor to
    /// enter and no thread it may block.
    ///
    /// Nesting is safe: entering from inside the runtime is a no-op, unlike
    /// `block_on`, which panics there.
    pub fn enter() -> EnterGuard<'static> {
        runtime().enter()
    }

    /// Drive a future to completion from a synchronous caller.
    ///
    /// # Panics
    ///
    /// Panics if called from within a tokio runtime context. Callers must be
    /// plain synchronous threads. Today the only caller is the Rustler NIF,
    /// which runs on BEAM scheduler threads. Never call this from code that
    /// also has to compile for wasm; use [`enter`] instead.
    pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
        runtime().block_on(future)
    }
}

#[cfg(target_arch = "wasm32")]
mod imp {
    /// No-op guard. A browser has a single implicit executor, so there is no
    /// context to enter, but callers stay identical across targets.
    pub struct EnterGuard;

    pub fn enter() -> EnterGuard {
        EnterGuard
    }
}

pub use imp::*;
