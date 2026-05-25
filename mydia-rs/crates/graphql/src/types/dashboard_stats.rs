use async_graphql::SimpleObject;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DashboardStats")]
pub struct DashboardStats {
    pub total_movies: i32,
    pub total_tv_shows: i32,
    pub total_episodes: i32,
    pub watched_episodes: i32,
    pub total_libraries: i32,
    pub missing_episodes: i32,
    pub monitored_movies: i32,
    pub monitored_tv_shows: i32,
}
