//! Hand-written `SeaORM` entities, derived from a one-time
//! `sea-orm-cli generate entity` snapshot against the Phoenix-migrated
//! Postgres schema and then hand-rewritten to use the cross-engine
//! wrapper types in [`mydia_rs_db::types`]. Add a new column by hand-
//! editing the appropriate file with the appropriate wrapper, then run
//! `schema-diff-check` locally to confirm the `SeaORM` entity matches
//! the Phoenix migration output.

pub mod prelude;

pub mod adult_files;
pub mod albums;
pub mod api_keys;
pub mod artists;
pub mod authors;
pub mod book_files;
pub mod books;
pub mod cardigann_definitions;
pub mod cardigann_search_sessions;
pub mod collection_items;
pub mod collections;
pub mod config_settings;
pub mod download_client_configs;
pub mod downloads;
pub mod episodes;
pub mod error_tracker_errors;
pub mod error_tracker_meta;
pub mod error_tracker_occurrences;
pub mod events;
pub mod import_list_items;
pub mod import_lists;
pub mod import_sessions;
pub mod indexer_configs;
pub mod library_paths;
pub mod media_files;
pub mod media_hashes;
pub mod media_items;
pub mod media_requests;
pub mod media_server_configs;
pub mod music_files;
pub mod mydia_runtime_lock;
pub mod oban_jobs;
pub mod oban_peers;
pub mod pairing_claims;
pub mod playback_progress;
pub mod playlist_tracks;
pub mod playlists;
pub mod quality_profiles;
pub mod release_blacklist;
pub mod remote_access_config;
pub mod remote_devices;
pub mod scenes;
pub mod schema_migrations;
pub mod sea_orm_active_enums;
pub mod search_backoffs;
pub mod studios;
pub mod subtitle_providers;
pub mod subtitles;
pub mod tracks;
pub mod transcode_jobs;
pub mod user_favorites;
pub mod user_integrations;
pub mod user_preferences;
pub mod users;
