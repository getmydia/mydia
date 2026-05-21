//! Download mutations — schema-shape stubs until U20 ships the
//! downloads pipeline. Each mutation returns a `not implemented` error
//! so the SDL contract holds and the parity replay harness flags these
//! consistently rather than skipping.

use async_graphql::{Context, Object, ID};

use crate::types::{
    CancelDownloadResult, DownloadJobStatus, DownloadOption, PrepareDownloadResult,
};

#[derive(Default)]
pub struct DownloadMutations;

#[Object]
impl DownloadMutations {
    async fn download_options(
        &self,
        _ctx: &Context<'_>,
        content_type: String,
        id: ID,
    ) -> async_graphql::Result<Vec<DownloadOption>> {
        let _ = (content_type, id);
        Err(async_graphql::Error::new(
            "Downloads not implemented yet (lands in U20)",
        ))
    }

    async fn prepare_download(
        &self,
        _ctx: &Context<'_>,
        content_type: String,
        id: ID,
        #[graphql(default = "720p")] resolution: String,
    ) -> async_graphql::Result<PrepareDownloadResult> {
        let _ = (content_type, id, resolution);
        Err(async_graphql::Error::new(
            "Downloads not implemented yet (lands in U20)",
        ))
    }

    async fn download_job_status(
        &self,
        _ctx: &Context<'_>,
        job_id: ID,
    ) -> async_graphql::Result<DownloadJobStatus> {
        let _ = job_id;
        Err(async_graphql::Error::new(
            "Downloads not implemented yet (lands in U20)",
        ))
    }

    async fn cancel_download_job(
        &self,
        _ctx: &Context<'_>,
        job_id: ID,
    ) -> async_graphql::Result<CancelDownloadResult> {
        let _ = job_id;
        Err(async_graphql::Error::new(
            "Downloads not implemented yet (lands in U20)",
        ))
    }
}
