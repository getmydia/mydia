//! Pagination info — port of `lib/mydia_web/schema/common_types.ex:68-74`.

use async_graphql::SimpleObject;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "PageInfo")]
pub struct PageInfo {
    pub has_next_page: bool,
    pub has_previous_page: bool,
    pub start_cursor: Option<String>,
    pub end_cursor: Option<String>,
}
