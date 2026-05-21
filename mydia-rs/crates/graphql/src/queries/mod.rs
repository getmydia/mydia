//! GraphQL query resolvers. Each module ports one Phoenix resolver
//! family from `lib/mydia_web/schema/resolvers/`:
//!
//! - [`browse`] — `list_movies`, `list_tv_shows`, `get_movie`, `get_tv_show`,
//!   `get_episode`, `list_libraries`, `list_season_episodes`, `get_season`,
//!   `get_library_path` (U10.a).
//! - [`discovery`] — continueWatching, recentlyAdded, upNext,
//!   favorites, unwatched (U10.b).
//! - [`media`] — derived field resolvers (overview, runtime, genres,
//!   artwork, files, progress) attached via `#[ComplexObject]`
//!   (U10.c).
//! - [`search`] — substring title search across media items (U11).
//! - [`streaming`] — `streamingCandidates(contentType, id)` (U11).
//! - [`api_key`] — `apiKeys` listing (U14).
//! - [`device`] — `devices` listing (U14 stub; U29 real).
//! - [`collection`] — `collections`, `collection`, `collectionItems`
//!   (U14).
//! - [`remote_access`] — `remoteAccessStatus` (U14 stub; U29 real).
//!
//! The resolvers are exposed as `#[Object]` structs; the top-level
//! schema combines them via `MergedObject` (see [`crate::schema`]).

pub mod api_key;
pub mod browse;
pub mod collection;
pub mod device;
pub mod discovery;
pub mod media;
pub mod remote_access;
pub mod search;
pub mod streaming;
