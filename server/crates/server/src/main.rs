use std::net::SocketAddr;

use mydia_server::router;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let addr: SocketAddr = "0.0.0.0:4001".parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("mydia-server listening on {addr}");

    axum::serve(listener, router::build_router())
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown signal received");
}
