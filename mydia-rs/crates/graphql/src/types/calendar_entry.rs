use async_graphql::{SimpleObject, ID};
use chrono::NaiveDate;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "CalendarEntry")]
pub struct CalendarEntry {
    pub id: ID,
    pub show_title: String,
    pub show_id: String,
    pub season_number: i32,
    pub episode_number: i32,
    pub episode_title: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub monitored: bool,
    pub has_file: bool,
}
