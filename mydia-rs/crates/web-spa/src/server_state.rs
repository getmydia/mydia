use std::sync::Arc;

use mydia_rs_db::DatabaseConnection;
use openidconnect::core::{CoreClient, CoreProviderMetadata};
use openidconnect::reqwest::async_http_client;
use openidconnect::{ClientId, ClientSecret, IssuerUrl, RedirectUrl, Scope};

#[derive(Debug, Clone)]
pub struct OidcSettings {
    pub issuer: Option<String>,
    pub discovery_document_uri: Option<String>,
    pub client_id: String,
    pub client_secret: String,
    pub redirect_uri: String,
    pub scopes: String,
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

        Some(Self { client, scopes })
    }
}

#[derive(Clone)]
pub struct SpaState {
    pub db: DatabaseConnection,
    pub oidc: Option<Arc<OidcContext>>,
}

impl SpaState {
    pub fn new(db: DatabaseConnection, oidc: Option<Arc<OidcContext>>) -> Self {
        Self { db, oidc }
    }

    pub fn oidc_available(&self) -> bool {
        self.oidc.is_some()
    }
}
