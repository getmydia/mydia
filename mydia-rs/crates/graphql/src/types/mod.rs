//! GraphQL types matching the Absinthe schema shapes in
//! `lib/mydia_web/schema/media_types.ex` and the shared types in
//! `lib/mydia_web/schema/common_types.ex`.
//!
//! Each type lives in its own module. SimpleObject fields are
//! direct shape; resolvers that compute derived fields (metadata
//! access, files, progress) live alongside in `#[ComplexObject]`
//! impls. The plan's `Verification` clause for U10 is that responses
//! match Phoenix output on a shared fixture DB, so field names and
//! types are pinned to Absinthe's emission.

pub mod artwork;
pub mod discovery;
pub mod episode;
pub mod library_path;
pub mod media_file;
pub mod movie;
pub mod page_info;
pub mod progress;
pub mod season;
pub mod tv_show;

pub use artwork::Artwork;
pub use discovery::{ContinueWatchingItem, MediaType, RecentlyAddedItem, UpNextItem};
pub use episode::Episode;
pub use library_path::{LibraryPath, LibraryType};
pub use media_file::MediaFile;
pub use movie::{Movie, MovieConnection, MovieEdge};
pub use page_info::PageInfo;
pub use progress::Progress;
pub use season::Season;
pub use tv_show::{TvShow, TvShowConnection, TvShowEdge};
