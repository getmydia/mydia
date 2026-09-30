//! Bundled Plex media-server plugin.
//!
//! Owns the plex.tv and Plex Media Server protocol, endpoint probing, the
//! mapping crawl and the watched-sync loop. Talks to Mydia only through the
//! `mydia:plugin@1.4.0` host imports, wrapped by `host::Host`.

// The helper modules are consumed by the setup, crawl and sync code that later
// commits add; until then their items are only exercised by tests.
#![allow(dead_code)]

mod api;
mod endpoint;
mod guid;
mod host;
mod http;
mod plextv;
mod reconcile;
mod setup;
mod store;
mod time;

use mydia_plugin_sdk::types::{Event, Health, ScheduleTick, SetupRequest, SetupScreen};

// Interim: each export is replaced by its real implementation later in this
// plan (on_event, on_schedule and check_health in Task 16).
#[mydia_plugin_sdk::plugin(on_schedule = on_schedule, setup = setup, check_health = check_health)]
fn on_event(_evt: Event) -> Result<String, String> {
    Err("plex plugin: on-event is wired in Task 16".to_string())
}

fn on_schedule(_tick: ScheduleTick) -> Result<String, String> {
    Err("plex plugin: on-schedule is wired in Task 16".to_string())
}

fn setup(req: SetupRequest) -> Result<SetupScreen, String> {
    let mut host = host::WasmHost::new();
    setup::run(&mut host, &req)
}

fn check_health() -> Result<Health, String> {
    Err("plex plugin: check-health is wired in Task 16".to_string())
}
