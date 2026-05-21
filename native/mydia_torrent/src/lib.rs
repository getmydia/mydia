use mydia_torrent_core::Engine;
use rustler::{Encoder, Env, LocalPid, OwnedEnv, ResourceArc, Term};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        metadata_ready,
        torrent_complete,
        torrent_error,
    }
}

struct EngineResource {
    engine: Arc<Engine>,
    runtime: Arc<Runtime>,
}

unsafe impl Send for EngineResource {}
unsafe impl Sync for EngineResource {}
impl std::panic::RefUnwindSafe for EngineResource {}
impl std::panic::UnwindSafe for EngineResource {}

#[rustler::resource_impl]
impl rustler::Resource for EngineResource {}

// Wrap each NIF body in `catch_unwind` so a Rust panic at the FFI boundary
// becomes an Elixir `{:error, "librqbit panic: ..."}` tuple instead of UB
// (unwinding across the FFI is undefined behavior). The Cargo profile is
// kept at the default `panic = "unwind"` precisely to make this possible.
fn nif_panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        format!("librqbit panic: {}", s)
    } else if let Some(s) = payload.downcast_ref::<String>() {
        format!("librqbit panic: {}", s)
    } else {
        "librqbit panic (non-string payload)".to_string()
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn start_engine(env: Env, staging_dir: String) -> Term {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let runtime = match Runtime::new() {
            Ok(rt) => rt,
            Err(e) => return Err(e.to_string()),
        };

        let engine = match runtime.block_on(async { Engine::new(staging_dir).await }) {
            Ok(e) => e,
            Err(e) => return Err(e.to_string()),
        };

        Ok(ResourceArc::new(EngineResource {
            engine: Arc::new(engine),
            runtime: Arc::new(runtime),
        }))
    }));

    match result {
        Ok(Ok(resource)) => (atoms::ok(), resource).encode(env),
        Ok(Err(msg)) => (atoms::error(), msg).encode(env),
        Err(payload) => (atoms::error(), nif_panic_message(payload)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn add_torrent(
    env: Env,
    resource: ResourceArc<EngineResource>,
    pid: LocalPid,
    magnet: String,
) -> Term {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let engine = resource.engine.clone();
        let runtime = resource.runtime.clone();

        runtime.spawn(async move {
            match engine.add_magnet(&magnet).await {
                Ok(resp) => {
                    let mut msg_env = OwnedEnv::new();
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        (
                            atoms::ok(),
                            resp.result_type,
                            resp.torrent_id,
                            resp.info_hash,
                            resp.file_id,
                            resp.staging_path,
                            resp.total_bytes,
                        )
                            .encode(env)
                    });
                }
                Err(e) => {
                    let mut msg_env = OwnedEnv::new();
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        (atoms::error(), e.to_string()).encode(env)
                    });
                }
            }
        });
    }));

    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(payload) => (atoms::error(), nif_panic_message(payload)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_chunk(
    env: Env,
    resource: ResourceArc<EngineResource>,
    torrent_id: usize,
    file_id: usize,
    offset: u64,
    len: usize,
) -> Term {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let engine = resource.engine.clone();
        let runtime = resource.runtime.clone();

        runtime.block_on(async { engine.read_chunk(torrent_id, file_id, offset, len).await })
    }));

    match result {
        Ok(Ok(data)) => (atoms::ok(), data).encode(env),
        Ok(Err(e)) => (atoms::error(), e.to_string()).encode(env),
        Err(payload) => (atoms::error(), nif_panic_message(payload)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn cancel_torrent(
    env: Env,
    resource: ResourceArc<EngineResource>,
    torrent_id: usize,
    delete_files: bool,
) -> Term {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let engine = resource.engine.clone();
        let runtime = resource.runtime.clone();

        runtime.block_on(async { engine.delete_torrent(torrent_id, delete_files).await })
    }));

    match result {
        Ok(Ok(_)) => atoms::ok().encode(env),
        Ok(Err(e)) => (atoms::error(), e.to_string()).encode(env),
        Err(payload) => (atoms::error(), nif_panic_message(payload)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn cancel_torrent_by_infohash(
    env: Env,
    resource: ResourceArc<EngineResource>,
    info_hash: String,
    delete_files: bool,
) -> Term {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let engine = resource.engine.clone();
        let runtime = resource.runtime.clone();

        runtime.block_on(async { engine.delete_torrent_by_infohash(&info_hash, delete_files).await })
    }));

    match result {
        Ok(Ok(_)) => atoms::ok().encode(env),
        Ok(Err(e)) => (atoms::error(), e.to_string()).encode(env),
        Err(payload) => (atoms::error(), nif_panic_message(payload)).encode(env),
    }
}

rustler::init!("Elixir.Mydia.Torrent");
