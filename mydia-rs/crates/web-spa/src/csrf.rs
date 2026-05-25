use axum::{
    body::Body,
    http::{Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};

const CSRF_HEADER: &str = "X-Mydia-Client";
const ALLOWED_CLIENTS: &[&str] = &["web", "player"];

pub async fn csrf_middleware(request: Request<Body>, next: Next) -> Response {
    if request.method() == axum::http::Method::GET {
        return next.run(request).await;
    }

    let client_value = request
        .headers()
        .get(CSRF_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if ALLOWED_CLIENTS.contains(&client_value) {
        return next.run(request).await;
    }

    (
        StatusCode::FORBIDDEN,
        [(axum::http::header::CONTENT_TYPE, "application/json")],
        r#"{"error":"csrf_required"}"#,
    )
        .into_response()
}
