use axum::{Extension, Router};
use http::{HeaderName, HeaderValue};
use mydia_rs_web_spa::api as web_api;
use mydia_rs_web_spa::session_config::SessionLayer;
use mydia_rs_web_spa::{security, WebState};
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::compression::CompressionLayer;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

pub fn build_router(
    state: WebState,
    graphql_schema: mydia_rs_graphql::MydiaSchema,
    session_layer: SessionLayer,
) -> Router {
    let router = mydia_rs_web_spa::router(state.clone());
    let router = router.merge(mydia_rs_graphql::axum_handler::router(graphql_schema));
    let router = router.merge(web_api::router(state.clone()));
    let router = session_layer.attach(router);

    let csp = if cfg!(debug_assertions) {
        security::CONTENT_SECURITY_POLICY_DEV
    } else {
        security::CONTENT_SECURITY_POLICY_BASELINE
    };

    router
        .layer(Extension(state))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static(csp),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("referrer-policy"),
            HeaderValue::from_static(security::REFERRER_POLICY),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("x-content-type-options"),
            HeaderValue::from_static(security::X_CONTENT_TYPE_OPTIONS),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("x-frame-options"),
            HeaderValue::from_static(security::X_FRAME_OPTIONS),
        ))
        .layer(PropagateRequestIdLayer::new(REQUEST_ID_HEADER))
        .layer(SetRequestIdLayer::new(REQUEST_ID_HEADER, MakeRequestUuid))
        .layer(CatchPanicLayer::new())
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_rs_jobs::storage::JobStorage;
    use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
    use mydia_rs_pubsub::Pubsub;
    use mydia_rs_web_spa::session_config;
    use sea_orm::Database;

    async fn test_state_and_session() -> (WebState, mydia_rs_graphql::MydiaSchema, SessionLayer) {
        use async_graphql::Schema;
        use mydia_rs_graphql::{subscriptions::SubscriptionRoot, MutationRoot, QueryRoot};

        let db = Database::connect("sqlite::memory:")
            .await
            .expect("in-memory sqlite");
        session_config::migrate(&db)
            .await
            .expect("tower-sessions migrate");
        let pubsub = Pubsub::new();
        let storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);
        let session_layer = session_config::layer(&db, false);

        let schema = Schema::build(
            QueryRoot::default(),
            MutationRoot::default(),
            SubscriptionRoot,
        )
        .finish();

        (
            WebState::new(db, pubsub, storage, None),
            schema,
            session_layer,
        )
    }

    #[test]
    fn build_router_compiles() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build runtime");
        let (state, schema, session_layer) = runtime.block_on(test_state_and_session());
        let _router = build_router(state, schema, session_layer);
    }
}
