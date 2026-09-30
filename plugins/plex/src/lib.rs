//! Bundled Plex media-server plugin.
//!
//! Owns the plex.tv and Plex Media Server protocol, endpoint probing, the
//! mapping crawl and the watched-sync loop. Talks to Mydia only through the
//! `mydia:plugin@1.4.0` host imports, wrapped by `host::Host`.

mod api;
mod endpoint;
mod events;
mod guid;
mod health;
mod host;
mod http;
mod mapping;
mod plextv;
mod reconcile;
mod schedule;
mod setup;
mod store;
mod sync;
mod time;

use mydia_plugin_sdk::types::{Event, Health, ScheduleTick, SetupRequest, SetupScreen};

#[mydia_plugin_sdk::plugin(on_schedule = on_schedule, setup = setup, check_health = check_health)]
fn on_event(evt: Event) -> Result<String, String> {
    let mut host = host::WasmHost::new();
    events::handle(&mut host, &evt)
}

fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    let mut host = host::WasmHost::new();
    schedule::run(&mut host, &tick.config_json)
}

fn setup(req: SetupRequest) -> Result<SetupScreen, String> {
    let mut host = host::WasmHost::new();
    setup::run(&mut host, &req)
}

fn check_health() -> Result<Health, String> {
    let mut host = host::WasmHost::new();
    health::check(&mut host)
}
