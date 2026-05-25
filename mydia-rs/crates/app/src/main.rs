use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context};
use clap::Parser;
use mydia_rs_app::runtime_lock::{self, RuntimeLockError, RuntimeLockHandle};
use mydia_rs_app::server;
use mydia_rs_config::{tracing_setup, Config};
use mydia_rs_db::{connect_from_config, schema_check, DatabaseConnection, SchemaCheckOutcome};
use mydia_rs_downloads::{DownloadService, JobManager, ServiceConfig as DownloadServiceConfig};
use mydia_rs_graphql::MydiaSchema;
use mydia_rs_jobs::storage::{self as jobs_storage, JobStorage};
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_p2p::{
    server::Server as P2pServer, server::ServerConfig as P2pServerConfig, MinimalRouter,
};
use mydia_rs_pubsub::Pubsub;
use mydia_rs_web_spa::server_state::{OidcContext, OidcSettings};
use mydia_rs_web_spa::session_config as web_session;
use mydia_rs_web_spa::WebState;
use sea_orm::DbBackend;

#[derive(Debug, Parser)]
#[command(name = "mydia-rs", version, about = "mydia Rust backend")]
struct Cli {
    #[arg(long, env = "MYDIA_CONFIG", value_name = "PATH")]
    config: Option<PathBuf>,

    #[arg(long, env = "MYDIA_KEEP_ALIVE", default_value_t = false)]
    keep_alive: bool,
}

struct BootState {
    web_state: WebState,
    db: DatabaseConnection,
    graphql_schema: MydiaSchema,
    _lock: Option<RuntimeLockHandle>,
    _p2p_server: Option<P2pServer>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    let config = match Config::load(cli.config.as_deref()) {
        Ok(cfg) => cfg,
        Err(err) => {
            eprintln!("mydia-rs: configuration error: {err}");
            std::process::exit(1);
        }
    };

    if let Err(err) = tracing_setup::install(&config.logging) {
        eprintln!("mydia-rs: failed to install tracing subscriber: {err}");
        std::process::exit(1);
    }

    let config = Arc::new(config);
    let keep_alive = cli.keep_alive;

    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        db_type = ?config.database.db_type,
        host = %config.server.host,
        port = config.server.port,
        keep_alive,
        "mydia-rs boot starting"
    );

    let boot = bootstrap(&config).await.map(Arc::new)?;

    let session_layer = web_session::layer(&boot.db, !cfg!(debug_assertions));
    let router = server::build_router(
        boot.web_state.clone(),
        boot.graphql_schema.clone(),
        session_layer,
    );

    let addr = format!("{}:{}", config.server.host, config.server.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(addr = %addr, "listening");

    axum::serve(listener, router).await?;

    // Hold BootState alive.
    let _boot = boot;
    Ok(())
}

async fn bootstrap(config: &Config) -> anyhow::Result<BootState> {
    let db = connect_from_config(config)
        .await
        .context("failed to open database")?;

    match schema_check(&db).await.context("schema check failed")? {
        SchemaCheckOutcome::Match { version } => {
            tracing::info!(version, "schema check passed");
        }
        SchemaCheckOutcome::SchemaAhead { version } => {
            tracing::warn!(version, "schema ahead of binary; continuing");
        }
        SchemaCheckOutcome::SchemaTooOld { version } => {
            return Err(anyhow!(
                "schema older than binary expects (version {version}); refusing to start"
            ));
        }
        SchemaCheckOutcome::SchemaMissing => {
            tracing::warn!("schema_migrations missing; this may not be a mydia database");
        }
    }

    let lock_enabled = !matches!(
        std::env::var("MYDIA_RS_DEV_SKIP_LOCK")
            .unwrap_or_default()
            .to_lowercase()
            .as_str(),
        "true" | "1" | "yes" | "on"
    );

    let lock = if lock_enabled && db.get_database_backend() == DbBackend::Sqlite {
        match runtime_lock::acquire(&db).await {
            Ok(handle) => Some(handle),
            Err(RuntimeLockError::Held) => {
                return Err(anyhow!(
                    "another mydia instance is running against this database; refusing to start"
                ));
            }
            Err(err) => {
                return Err(anyhow::Error::new(err).context("failed to acquire runtime lock"));
            }
        }
    } else if !lock_enabled {
        tracing::warn!(
            "MYDIA_RS_DEV_SKIP_LOCK=true — boot-time mutual-exclusion lock skipped. \
             DEV ONLY; production must not set this."
        );
        None
    } else {
        tracing::info!(
            "runtime_lock skipped on non-SQLite backend; Phoenix advisory-lock owns Postgres mutual exclusion"
        );
        None
    };

    jobs_storage::setup(&db)
        .await
        .context("apalis storage setup failed")?;

    web_session::migrate(&db)
        .await
        .context("tower-sessions table migration failed")?;

    let pubsub = Pubsub::new();
    let _library_scanner_storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);

    let oidc = build_oidc_context(config).await.map(Arc::new);

    let streaming_supervisor =
        mydia_rs_streaming::Supervisor::new(streaming_config(), pubsub.clone());
    let graphql_schema = mydia_rs_graphql::build_schema(
        mydia_rs_graphql::GraphqlAppState::with_pubsub(db.clone(), pubsub.clone()),
    );

    let download_job_manager = JobManager::new(2);
    let download_service = DownloadService::new(
        db.clone(),
        download_job_manager,
        pubsub.clone(),
        download_service_config(),
    );

    let mut web_state = WebState::new(db.clone(), pubsub, _library_scanner_storage, oidc)
        .with_streaming_supervisor(streaming_supervisor.clone())
        .with_download_service(download_service);

    if let Some(secret) = config.server.guardian_secret_key.as_ref() {
        let leeway_secs = u64::from(config.auth.jwt_allowed_drift_ms) / 1000;
        let signer = mydia_rs_auth::MediaTokenSigner::new(secret, leeway_secs);
        let cache = mydia_rs_auth::MediaTokenCache::new(std::time::Duration::from_secs(300));
        web_state = web_state.with_media_signer(signer, cache);
    } else {
        tracing::warn!(
            "config.server.guardian_secret_key is unset; \
             /api/v1/stream and /api/v1/hls will reject every request \
             until a secret is configured"
        );
    }

    if let Ok(path) = std::env::var("MYDIA_GENERATED_MEDIA_PATH") {
        web_state = web_state.with_generated_media_path(std::path::PathBuf::from(path));
    }

    let p2p_server = maybe_boot_p2p(
        config,
        &db,
        streaming_supervisor.clone(),
        graphql_schema.clone(),
    );

    if let Some(server) = p2p_server.as_ref() {
        web_state = web_state.with_p2p_server(server.handle());
    }

    tracing::info!("mydia-rs boot ok");

    Ok(BootState {
        web_state,
        db,
        graphql_schema,
        _lock: lock,
        _p2p_server: p2p_server,
    })
}

fn maybe_boot_p2p(
    config: &Config,
    db: &DatabaseConnection,
    streaming_supervisor: mydia_rs_streaming::Supervisor,
    graphql_schema: MydiaSchema,
) -> Option<P2pServer> {
    if !config.features.remote_access_enabled {
        tracing::info!("remote access disabled in config; skipping p2p Server");
        return None;
    }
    let Some(keypair_path) = config.p2p.keypair_path.clone() else {
        tracing::warn!(
            "remote access enabled but config.p2p.keypair_path is unset; \
             skipping p2p Server (paired devices would not reconnect across restarts)"
        );
        return None;
    };

    let Some(guardian_secret) = config.server.guardian_secret_key.clone() else {
        tracing::error!(
            "remote access enabled but config.server.guardian_secret_key is unset; \
             refusing to boot p2p (issued tokens would be unverifiable by Phoenix)"
        );
        return None;
    };

    let leeway_secs = u64::from(config.auth.jwt_allowed_drift_ms) / 1000;
    let media_signer = mydia_rs_auth::MediaTokenSigner::new(&guardian_secret, leeway_secs);
    let access_signer = mydia_rs_auth::AccessTokenSigner::new(&guardian_secret, leeway_secs);
    let rate_limiter = mydia_rs_p2p::ClaimRateLimiter::new_default();
    let media_token_cache =
        mydia_rs_auth::MediaTokenCache::new(std::time::Duration::from_secs(5 * 60));

    let router = std::sync::Arc::new(
        MinimalRouter::new(db.clone(), media_signer, access_signer, rate_limiter)
            .with_graphql_schema(graphql_schema)
            .with_streaming(streaming_supervisor, media_token_cache),
    );

    let server_config = P2pServerConfig {
        relay_url: std::env::var("IROH_RELAY_URL").ok(),
        bind_port: std::env::var("MYDIA_P2P_BIND_PORT")
            .ok()
            .and_then(|s| s.parse().ok()),
        keypair_path: Some(keypair_path.clone()),
    };

    tracing::info!(
        keypair_path = %keypair_path,
        "booting p2p server"
    );
    let server = P2pServer::spawn(server_config, router);
    tracing::info!(node_id = %server.handle().node_id(), "p2p server up");
    Some(server)
}

fn streaming_config() -> mydia_rs_streaming::SupervisorConfig {
    let mut cfg = mydia_rs_streaming::SupervisorConfig::default();
    if let Ok(dir) = std::env::var("MYDIA_HLS_TEMP_DIR") {
        cfg.temp_base_dir = std::path::PathBuf::from(dir);
    }
    if let Ok(path) = std::env::var("MYDIA_FFMPEG_PATH") {
        cfg.ffmpeg_path = std::path::PathBuf::from(path);
    }
    cfg
}

fn download_service_config() -> DownloadServiceConfig {
    let mut cfg = DownloadServiceConfig::default();
    if let Ok(dir) = std::env::var("MYDIA_TRANSCODE_CACHE_DIR") {
        cfg.transcode_cache_dir = std::path::PathBuf::from(dir);
    }
    if let Ok(path) = std::env::var("MYDIA_FFMPEG_PATH") {
        cfg.ffmpeg_path = std::path::PathBuf::from(path);
    }
    cfg
}

async fn build_oidc_context(config: &Config) -> Option<OidcContext> {
    let auth = &config.auth;
    if !auth.oidc_enabled {
        tracing::debug!("OIDC disabled in config; skipping discovery");
        return None;
    }

    let (Some(client_id), Some(client_secret), Some(redirect_uri)) = (
        auth.oidc_client_id.clone(),
        auth.oidc_client_secret.clone(),
        auth.oidc_redirect_uri.clone(),
    ) else {
        tracing::error!(
            "OIDC enabled but client_id / client_secret / redirect_uri missing — skipping"
        );
        return None;
    };

    let settings = OidcSettings {
        issuer: auth.oidc_issuer.clone(),
        discovery_document_uri: auth.oidc_discovery_document_uri.clone(),
        client_id,
        client_secret,
        redirect_uri,
        scopes: auth.oidc_scopes.clone(),
        disable_par: auth.oidc_disable_par,
    };

    match OidcContext::try_build(&settings).await {
        Some(ctx) => {
            tracing::info!(
                issuer = ?settings.issuer,
                "OIDC provider discovered; PKCE flow available at /auth/oidc/login"
            );
            Some(ctx)
        }
        None => None,
    }
}
