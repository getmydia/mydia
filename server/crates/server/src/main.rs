use std::net::SocketAddr;

use mydia_server::router;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let bootstrap = mydia_config::Loader::new().with_env().load()?;
    std::fs::create_dir_all(&bootstrap.config.data_dir)?;

    let db = mydia_db::pool::connect(&bootstrap.config.data_dir.join("mydia.db")).await?;

    // The overlay lives in the database, so configuration is loaded twice:
    // once to find the database, then again with the overlay applied.
    let overlay = mydia_config::db_provider::read_overlay(&db).await?;
    let loaded = mydia_config::Loader::new()
        .with_env()
        .with_overlay(overlay)
        .load()?;

    let ctx = mydia_api::context::ApiContext {
        db,
        issuer: mydia_auth::tokens::Issuer::new(loaded.config.secret_key_base.as_bytes()),
    };

    let addr: SocketAddr =
        format!("{}:{}", loaded.config.bind_address, loaded.config.port).parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("mydia-server listening on {addr}");

    axum::serve(listener, router::build_router(ctx))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown signal received");
}
