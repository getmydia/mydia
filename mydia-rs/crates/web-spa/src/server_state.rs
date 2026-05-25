use std::sync::Arc;

use mydia_rs_auth::{MediaTokenCache, MediaTokenSigner};
use mydia_rs_db::DatabaseConnection;
use mydia_rs_downloads::DownloadService;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_p2p::ServerHandle as P2pServerHandle;
use mydia_rs_pubsub::Pubsub;
use mydia_rs_streaming::Supervisor as StreamingSupervisor;
use openidconnect::core::{CoreClient, CoreProviderMetadata};
use openidconnect::reqwest::async_http_client;
use openidconnect::{ClientId, ClientSecret, IssuerUrl, RedirectUrl, Scope};

use crate::download_probes::ProbeCache;
use crate::indexer_probes::IndexerProbeCache;

#[derive(Debug, Clone)]
pub struct OidcSettings {
    pub issuer: Option<String>,
    pub discovery_document_uri: Option<String>,
    pub client_id: String,
    pub client_secret: String,
    pub redirect_uri: String,
    pub scopes: String,
    pub disable_par: bool,
}

#[derive(Clone)]
pub struct OidcContext {
    pub(crate) client: CoreClient,
    pub(crate) scopes: Vec<Scope>,
}

impl OidcContext {
    pub async fn try_build(settings: &OidcSettings) -> Option<Self> {
        let Some(issuer_str) = settings
            .discovery_document_uri
            .as_deref()
            .or(settings.issuer.as_deref())
        else {
            tracing::error!("OIDC enabled but neither issuer nor discovery_document_uri set");
            return None;
        };
        let issuer_url = match IssuerUrl::new(issuer_str.to_owned()) {
            Ok(u) => u,
            Err(err) => {
                tracing::error!(%err, value = issuer_str, "invalid OIDC issuer URL");
                return None;
            }
        };

        let metadata =
            match CoreProviderMetadata::discover_async(issuer_url, async_http_client).await {
                Ok(m) => m,
                Err(err) => {
                    tracing::error!(%err, "OIDC provider metadata discovery failed");
                    return None;
                }
            };

        let redirect = match RedirectUrl::new(settings.redirect_uri.clone()) {
            Ok(u) => u,
            Err(err) => {
                tracing::error!(%err, "invalid OIDC redirect URI");
                return None;
            }
        };

        let client = CoreClient::from_provider_metadata(
            metadata,
            ClientId::new(settings.client_id.clone()),
            Some(ClientSecret::new(settings.client_secret.clone())),
        )
        .set_redirect_uri(redirect);

        let scopes = settings
            .scopes
            .split_whitespace()
            .map(|s| Scope::new(s.to_owned()))
            .collect();

        if settings.disable_par {
            tracing::info!("OIDC_DISABLE_PAR is set; openidconnect 3.x never uses PAR — no-op");
        }

        Some(Self { client, scopes })
    }
}

#[derive(Clone)]
pub struct WebState {
    pub db: DatabaseConnection,
    pub pubsub: Pubsub,
    pub library_scanner_storage: JobStorage<LibraryScannerArgs>,
    pub oidc: Option<Arc<OidcContext>>,
    pub media_signer: Option<MediaTokenSigner>,
    pub media_token_cache: Option<MediaTokenCache>,
    pub generated_media_path: Arc<std::path::PathBuf>,
    pub streaming_supervisor: Option<StreamingSupervisor>,
    pub p2p_server: Option<P2pServerHandle>,
    pub download_probes: ProbeCache,
    pub indexer_probes: IndexerProbeCache,
    pub download_service: Option<DownloadService>,
}

impl WebState {
    #[must_use]
    pub fn new(
        db: DatabaseConnection,
        pubsub: Pubsub,
        library_scanner_storage: JobStorage<LibraryScannerArgs>,
        oidc: Option<Arc<OidcContext>>,
    ) -> Self {
        Self {
            db,
            pubsub,
            library_scanner_storage,
            oidc,
            media_signer: None,
            media_token_cache: None,
            generated_media_path: Arc::new(default_generated_media_path()),
            streaming_supervisor: None,
            p2p_server: None,
            download_probes: ProbeCache::new(),
            indexer_probes: IndexerProbeCache::new(),
            download_service: None,
        }
    }

    #[must_use]
    pub fn with_download_probes(mut self, probes: ProbeCache) -> Self {
        self.download_probes = probes;
        self
    }

    #[must_use]
    pub fn with_indexer_probes(mut self, probes: IndexerProbeCache) -> Self {
        self.indexer_probes = probes;
        self
    }

    #[must_use]
    pub fn with_media_signer(mut self, signer: MediaTokenSigner, cache: MediaTokenCache) -> Self {
        self.media_signer = Some(signer);
        self.media_token_cache = Some(cache);
        self
    }

    #[must_use]
    pub fn with_generated_media_path(mut self, path: std::path::PathBuf) -> Self {
        self.generated_media_path = Arc::new(path);
        self
    }

    #[must_use]
    pub fn with_streaming_supervisor(mut self, supervisor: StreamingSupervisor) -> Self {
        self.streaming_supervisor = Some(supervisor);
        self
    }

    #[must_use]
    pub fn with_download_service(mut self, service: DownloadService) -> Self {
        self.download_service = Some(service);
        self
    }

    #[must_use]
    pub fn with_p2p_server(mut self, handle: P2pServerHandle) -> Self {
        self.p2p_server = Some(handle);
        self
    }

    #[must_use]
    pub fn oidc_available(&self) -> bool {
        self.oidc.is_some()
    }
}

fn default_generated_media_path() -> std::path::PathBuf {
    std::env::var("MYDIA_GENERATED_MEDIA_PATH")
        .ok()
        .map_or_else(|| std::path::PathBuf::from("priv/generated"), Into::into)
}
