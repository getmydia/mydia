//! System status type — matches the Dioxus `SystemStatus` struct from
//! `crates/web/src/server_fns/admin/system.rs`.

use async_graphql::SimpleObject;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SetupCounts")]
pub struct SetupCounts {
    pub user_count: i32,
    pub media_count: i32,
    pub library_path_count: i32,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SystemStatus")]
pub struct SystemStatus {
    pub app_version: String,
    pub build_target: String,
    pub database_adapter: String,
    pub database_health: String,
    pub database_size: String,
    pub database_location: String,
    pub uptime: String,
    pub library_paths_count: i32,
    pub download_clients_count: i32,
    pub indexers_count: i32,
    pub active_transcodes: i32,
    pub active_streaming_sessions: i32,
    pub setup_counts: SetupCounts,
}
