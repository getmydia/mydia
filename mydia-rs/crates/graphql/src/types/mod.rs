//! GraphQL types matching the Absinthe schema shapes in
//! `lib/mydia_web/schema/media_types.ex` and the shared types in
//! `lib/mydia_web/schema/common_types.ex`.
//!
//! Each type lives in its own module. `SimpleObject` fields are
//! direct shape; resolvers that compute derived fields (metadata
//! access, files, progress) live alongside in `#[ComplexObject]`
//! impls.

pub mod activity_event;
pub mod admin_download;
pub mod admin_job;
pub mod admin_transcode;
pub mod api_key;
pub mod artwork;
pub mod calendar_entry;
pub mod collection;
pub mod dashboard_stats;
pub mod discovery;
pub mod download;
pub mod download_client;
pub mod episode;
pub mod import_list;
pub mod import_list_item;
pub mod import_session;
pub mod indexer;
pub mod library_path;
pub mod login;
pub mod media_file;
pub mod media_server;
pub mod movie;
pub mod page_info;
pub mod progress;
pub mod quality_profile;
pub mod release_blacklist;
pub mod remote_access;
pub mod remote_device;
pub mod request;
pub mod search_result;
pub mod season;
pub mod setting;
pub mod streaming;
pub mod subtitle;
pub mod system_status;
pub mod toggle_favorite_result;
pub mod tv_show;
pub mod user;
pub mod user_profile;
pub mod user_row;

pub use activity_event::ActivityEvent;
pub use admin_download::DownloadRecord;
pub use admin_job::{JobEvent, WorkerSummary};
pub use admin_transcode::TranscodeJob;
pub use api_key::{ApiKeyObject, CreateApiKeyResult};
pub use artwork::Artwork;
pub use calendar_entry::CalendarEntry;
pub use collection::CollectionObject;
pub use dashboard_stats::DashboardStats;
pub use discovery::{
    ContinueWatchingItem, DiscoverItem, DiscoverPage, MediaType, RecentlyAddedItem, UpNextItem,
};
pub use download::{
    CancelDownloadResult, DownloadJobStatus, DownloadOption, PrepareDownloadResult,
};
pub use download_client::DownloadClient;
pub use episode::Episode;
pub use import_list::ImportList;
pub use import_list_item::ImportListItem;
pub use import_session::ImportSession;
pub use indexer::Indexer;
pub use library_path::{LibraryPath, LibraryType};
pub use login::{LoginInput, LoginResult};
pub use media_file::MediaFile;
pub use media_server::MediaServer;
pub use movie::{Movie, MovieConnection, MovieEdge};
pub use page_info::PageInfo;
pub use progress::Progress;
pub use quality_profile::QualityProfile;
pub use release_blacklist::ReleaseBlacklistEntry;
pub use remote_access::{ClaimCodeObject, MediaTokenObject, RemoteAccessStatus};
pub use remote_device::{RemoteDevice, RevokeDeviceResult};
pub use request::MediaRequest;
pub use search_result::{SearchResult, SearchResults};
pub use season::Season;
pub use setting::{ConfigSource, SettingRow};
pub use streaming::{
    StreamingCandidate, StreamingCandidateStrategy, StreamingCandidatesResult, StreamingMetadata,
    StreamingSessionResult, StreamingStrategy,
};
pub use subtitle::{SubtitleFormat, SubtitleTrack};
pub use system_status::{SetupCounts, SystemStatus};
pub use toggle_favorite_result::ToggleFavoriteResult;
pub use tv_show::{TvShow, TvShowConnection, TvShowEdge};
pub use user::UserObject;
pub use user_profile::UserProfile;
pub use user_row::{CreateUserInput, SetupAdminInput, UpdateUserRoleInput, UserRow};
