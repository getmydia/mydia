use mydia_torrent_core::Engine;
use rustler::{Env, ResourceArc, Term, Encoder, OwnedEnv, LocalPid};
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

#[rustler::nif(schedule = "DirtyIo")]
fn start_engine(env: Env, staging_dir: String) -> Term {
    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => return (atoms::error(), e.to_string()).encode(env),
    };

    let engine = match runtime.block_on(async { Engine::new(staging_dir).await }) {
        Ok(e) => e,
        Err(e) => return (atoms::error(), e.to_string()).encode(env),
    };

    let resource = ResourceArc::new(EngineResource {
        engine: Arc::new(engine),
        runtime: Arc::new(runtime),
    });

    (atoms::ok(), resource).encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn add_torrent(env: Env, resource: ResourceArc<EngineResource>, pid: LocalPid, magnet: String) -> Term {
    let engine = resource.engine.clone();
    let runtime = resource.runtime.clone();
    
    runtime.spawn(async move {
        match engine.add_magnet(&magnet).await {
            Ok(resp) => {
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&pid, |env| {
                    match resp {
                        librqbit::AddTorrentResponse::AlreadyManaged(t_id, handle) => {
                             (atoms::ok(), "already_exists", t_id, hex::encode(handle.info_hash().0)).encode(env)
                        }
                        librqbit::AddTorrentResponse::Added(t_id, handle) => {
                             (atoms::ok(), "added", t_id, hex::encode(handle.info_hash().0)).encode(env)
                        }
                        _ => (atoms::error(), "unsupported_response").encode(env)
                    }
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

    atoms::ok().encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_chunk(env: Env, resource: ResourceArc<EngineResource>, torrent_id: usize, file_id: usize, offset: u64, len: usize) -> Term {
    let engine = resource.engine.clone();
    let runtime = resource.runtime.clone();
    
    match runtime.block_on(async {
        engine.read_chunk(torrent_id, file_id, offset, len).await
    }) {
        Ok(data) => (atoms::ok(), data).encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn cancel_torrent(env: Env, resource: ResourceArc<EngineResource>, torrent_id: usize, delete_files: bool) -> Term {
    let engine = resource.engine.clone();
    let runtime = resource.runtime.clone();
    
    match runtime.block_on(async {
        engine.delete_torrent(torrent_id, delete_files).await
    }) {
        Ok(_) => atoms::ok().encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

rustler::init!("Elixir.Mydia.Torrent");
