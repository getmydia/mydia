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

    // No layer supplied a signing key. Generate one and persist it to the
    // database overlay so every later boot reuses it; a fixed default would
    // make every install share a key, and regenerating on every boot would
    // invalidate every issued token on restart.
    let had_secret_key_base = !loaded.config.secret_key_base.is_empty();
    let secret_key_base =
        mydia_config::db_provider::ensure_secret_key_base(&db, &loaded.config.secret_key_base)
            .await?;

    if !had_secret_key_base {
        tracing::info!("generated a new secret_key_base and saved it to the database");
    }

    if secret_key_base.is_empty() {
        return Err("secret_key_base could not be established; refusing to start with an empty JWT signing key".into());
    }

    let ctx = mydia_api::context::ApiContext {
        db,
        issuer: mydia_auth::tokens::Issuer::new(secret_key_base.as_bytes()),
    };

    // Configured paths are the only source of library paths in this slice.
    // A path removed from the configuration is removed from the database,
    // along with the items it owned. Nothing on disk is touched.
    let configured: Vec<(String, String)> = loaded
        .config
        .library
        .paths
        .iter()
        .map(|p| (p.path.display().to_string(), p.library_type.clone()))
        .collect();

    mydia_db::library_paths::sync_from_config(&ctx.db, &configured).await?;

    // A run left in `running` belongs to a process that died. Close it out
    // before starting anything, so the admin UI never shows a stale scan as
    // still in progress.
    mydia_db::scan_runs::abandon_running(&ctx.db).await?;

    let _scanner = mydia_server::scanner::spawn(ctx.db.clone(), loaded.config.library.clone());

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
