//! GraphQL query resolvers. Each module ports one Phoenix resolver
//! family from `lib/mydia_web/schema/resolvers/`:
//!
//! - [`browse`] — list_movies, list_tv_shows, get_movie, get_tv_show,
//!   get_episode, list_libraries, list_season_episodes, get_season,
//!   get_library_path (U10.a).
//! - [`discovery`] — continueWatching, recentlyAdded, upNext,
//!   favorites, unwatched (U10.b).
//! - [`media`] — derived field resolvers (overview, runtime, genres,
//!   artwork, files, progress) attached via `#[ComplexObject]`
//!   (U10.c).
//!
//! The resolvers are exposed as `#[Object]` structs; the top-level
//! schema combines them via `MergedObject` (see [`crate::schema`]).

pub mod browse;
pub mod discovery;
pub mod media;
