//! GraphQL types matching the Absinthe schema shapes in
//! `lib/mydia_web/schema/media_types.ex` and the shared types in
//! `lib/mydia_web/schema/common_types.ex`.
//!
//! Each type lives in its own module. SimpleObject fields are
//! direct shape; resolvers that compute derived fields (metadata
//! access, files, progress) live alongside in `#[ComplexObject]`
//! impls.

pub mod api_key;
pub mod artwork;
pub mod collection;
pub mod discovery;
pub mod download;
pub mod episode;
pub mod library_path;
pub mod login;
pub mod media_file;
pub mod movie;
pub mod page_info;
pub mod progress;
pub mod remote_access;
pub mod remote_device;
pub mod search_result;
pub mod season;
pub mod streaming;
pub mod subtitle;
pub mod toggle_favorite_result;
pub mod tv_show;
pub mod user;

pub use api_key::{ApiKeyObject, CreateApiKeyResult};
pub use artwork::Artwork;
pub use collection::CollectionObject;
pub use discovery::{ContinueWatchingItem, MediaType, RecentlyAddedItem, UpNextItem};
pub use download::{
    CancelDownloadResult, DownloadJobStatus, DownloadOption, PrepareDownloadResult,
};
pub use episode::Episode;
pub use library_path::{LibraryPath, LibraryType};
pub use login::{LoginInput, LoginResult};
pub use media_file::MediaFile;
pub use movie::{Movie, MovieConnection, MovieEdge};
pub use page_info::PageInfo;
pub use progress::Progress;
pub use remote_access::{ClaimCodeObject, MediaTokenObject, RemoteAccessStatus};
pub use remote_device::{RemoteDevice, RevokeDeviceResult};
pub use search_result::{SearchResult, SearchResults};
pub use season::Season;
pub use streaming::{
    StreamingCandidate, StreamingCandidateStrategy, StreamingCandidatesResult, StreamingMetadata,
    StreamingSessionResult, StreamingStrategy,
};
pub use subtitle::{SubtitleFormat, SubtitleTrack};
pub use toggle_favorite_result::ToggleFavoriteResult;
pub use tv_show::{TvShow, TvShowConnection, TvShowEdge};
pub use user::UserObject;
