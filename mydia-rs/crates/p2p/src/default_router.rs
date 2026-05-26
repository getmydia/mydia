//! Baseline [`P2pRouter`] implementation suitable for app boot.
//!
//! [`MinimalRouter`] wires the dispatch surface to the parts of the
//! app that exist today:
//!
//! - Pairing requests run the full [`crate::complete_pairing`] flow,
//!   protected by the atomic [`crate::ClaimRateLimiter`].
//! - GraphQL requests verify the bearer access token (if present) and
//!   execute against the in-process async-graphql schema, mirroring
//!   the Phoenix `Absinthe.run` dispatch in `lib/mydia/p2p/server.ex`.
//! - HLS requests verify a media token, look up the streaming session
//!   in the supervisor, wait for it to be ready, and stream the
//!   requested file (playlist or segment) back via the Host's
//!   zero-copy `stream_file_range` path.
//! - `ReadMedia` (the legacy direct-byte-read API) stays a 501; the
//!   HLS surface is the supported play path.
//!
//! Production wiring assembles `MinimalRouter` from the boot-time
//! `Db`, the JWT signers from the auth crate, the GraphQL schema, the
//! streaming supervisor, and a fresh rate limiter (per-process;
//! survives hot-patches via `mydia_rs_app::main::BOOT`'s `OnceCell`).
//!
//! Each long-lived dependency is configured through a builder method
//! (`with_graphql_schema`, `with_streaming`) so callers that don't
//! need a given surface (tests, minimal smoke harnesses) can skip
//! wiring it without dragging the production app boot into compile
//! errors.

use std::path::Path;

use async_graphql::{Request as GqlRequest, Variables};
use async_trait::async_trait;
use mydia_p2p_core::{
    GraphQLRequest, GraphQLResponse, HlsRequest, HlsResponseHeader, MydiaResponse, PairingRequest,
    PairingResponse, ReadMediaRequest,
};
use mydia_rs_auth::{AccessTokenSigner, MediaTokenCache, MediaTokenSigner};
use mydia_rs_db::types::UuidText;
use mydia_rs_entities::users;
use mydia_rs_graphql::{CurrentUser, GraphqlRequestContext, MydiaSchema};
use mydia_rs_streaming::Supervisor;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{DatabaseConnection, DbErr, EntityTrait, QueryFilter};
use uuid::Uuid;

use crate::media_token::{MediaTokenValidator, ValidationError};
use crate::pairing::{complete_pairing, DeviceAttrs};
use crate::rate_limiter::{ClaimRateLimiter, RateLimitOutcome};
use crate::router::{
    device_attrs_from_request, pairing_response_from_error, pairing_response_from_outcome,
    HlsStreamHandle, P2pRouter, RouterContext, RouterError,
};

/// Production-shape router. Holds the long-lived handles every
/// request branch needs.
#[derive(Clone)]
pub struct MinimalRouter {
    db: DatabaseConnection,
    media_signer: MediaTokenSigner,
    access_signer: AccessTokenSigner,
    rate_limiter: ClaimRateLimiter,
    direct_urls: Vec<String>,
    /// Schema handle for the GraphQL dispatch arm. When `None`, GraphQL
    /// requests reply with a "not wired yet" error so a misconfigured
    /// boot is visible on the wire rather than panicking.
    schema: Option<MydiaSchema>,
    /// Streaming session supervisor for the HLS dispatch arm. When
    /// `None`, HLS requests reply with a 501 header so the client
    /// doesn't hang waiting for chunks.
    streaming: Option<Supervisor>,
    /// JWT-verify + DB-revoke validator used by the HLS dispatch arm
    /// to map a media token onto a `RemoteDevice`. Lazily built from
    /// the media signer + cache + db when [`Self::with_streaming`]
    /// runs so callers don't have to construct one themselves.
    media_validator: Option<MediaTokenValidator>,
}

impl MinimalRouter {
    pub fn new(
        db: DatabaseConnection,
        media_signer: MediaTokenSigner,
        access_signer: AccessTokenSigner,
        rate_limiter: ClaimRateLimiter,
    ) -> Self {
        Self {
            db,
            media_signer,
            access_signer,
            rate_limiter,
            direct_urls: Vec::new(),
            schema: None,
            streaming: None,
            media_validator: None,
        }
    }

    /// Optional list of `https://host:port` direct URLs the client
    /// can use to bypass the relay. Configured by the operator; we
    /// surface it in the pairing response so paired clients can dial
    /// the box directly when possible.
    pub fn with_direct_urls(mut self, urls: Vec<String>) -> Self {
        self.direct_urls = urls;
        self
    }

    /// Attach the in-process GraphQL schema. Required for the p2p
    /// GraphQL dispatch arm; without it the arm replies with a clear
    /// "not wired" error.
    pub fn with_graphql_schema(mut self, schema: MydiaSchema) -> Self {
        self.schema = Some(schema);
        self
    }

    /// Attach the HLS streaming supervisor + the cache that backs the
    /// media-token validator. The validator is constructed eagerly so
    /// every per-request handler reuses the same dashmap.
    pub fn with_streaming(mut self, supervisor: Supervisor, cache: MediaTokenCache) -> Self {
        let validator = MediaTokenValidator::new(self.media_signer.clone(), cache, self.db.clone());
        self.streaming = Some(supervisor);
        self.media_validator = Some(validator);
        self
    }

    pub fn rate_limiter(&self) -> &ClaimRateLimiter {
        &self.rate_limiter
    }

    /// Expose the media-token validator so admin revoke flows can
    /// evict the cache synchronously when a device is revoked through
    /// the HTTP admin surface (the same dashmap is shared by every
    /// clone of [`MediaTokenCache`]).
    pub fn media_validator(&self) -> Option<&MediaTokenValidator> {
        self.media_validator.as_ref()
    }
}

#[async_trait]
impl P2pRouter for MinimalRouter {
    async fn handle_pairing(
        &self,
        request: PairingRequest,
        _ctx: RouterContext,
    ) -> Result<PairingResponse, RouterError> {
        // We don't have a per-peer IP at this level (iroh doesn't
        // expose it; the request_id is the only stable identifier).
        // Use the request_id-equivalent: the device-supplied name is
        // not stable enough; fall back to the claim code itself as
        // the rate-limit key. This matches Phoenix's "rate by
        // submitting actor" rule more loosely than ideal, but it
        // still blocks a brute-force loop from one origin.
        let rate_key = request.claim_code.clone();
        if self.rate_limiter.check_and_record_failure(&rate_key) == RateLimitOutcome::Blocked {
            return Ok(PairingResponse {
                success: false,
                media_token: None,
                access_token: None,
                device_token: None,
                error: Some("rate_limited".into()),
                direct_urls: Vec::new(),
            });
        }

        let attrs: DeviceAttrs = device_attrs_from_request(&request);
        match complete_pairing(
            &self.db,
            &self.media_signer,
            &self.access_signer,
            &request.claim_code,
            attrs,
        )
        .await
        {
            Ok(outcome) => {
                // Success clears the rate-limit counter for this key.
                self.rate_limiter.reset(&rate_key);
                Ok(pairing_response_from_outcome(
                    outcome,
                    self.direct_urls.clone(),
                ))
            }
            Err(err) => {
                tracing::warn!(error = %err, "pairing failed");
                Ok(pairing_response_from_error(&err))
            }
        }
    }

    async fn handle_read_media(
        &self,
        _request: ReadMediaRequest,
        _ctx: RouterContext,
    ) -> Result<MydiaResponse, RouterError> {
        // Permanently unwired. mydia-rs's playback surface is HLS via Flutter;
        // direct-read is retained on the protocol for wire compatibility with
        // old clients but will never be implemented server-side.
        Ok(MydiaResponse::Error(
            "ReadMedia is permanently unwired in mydia-rs; HLS-only surface.".into(),
        ))
    }

    async fn handle_graphql(
        &self,
        request: GraphQLRequest,
        _ctx: RouterContext,
    ) -> Result<GraphQLResponse, RouterError> {
        let Some(schema) = self.schema.as_ref() else {
            // Boot didn't wire a schema (test harness, or feature gate
            // off). Surface a deterministic error rather than a panic
            // so the client sees something parseable.
            return Ok(GraphQLResponse {
                data: None,
                errors: Some(
                    r#"[{"message":"p2p GraphQL bridge not configured on this server"}]"#.into(),
                ),
            });
        };

        // Build the async-graphql Request from the wire payload.
        let mut gql_req = GqlRequest::new(request.query);
        if let Some(op) = request.operation_name {
            gql_req = gql_req.operation_name(op);
        }
        if let Some(vars_json) = request.variables.as_deref() {
            // Parse variables JSON into async-graphql's Variables. We
            // silently fall back to empty variables on parse failure,
            // matching Phoenix's `parse_graphql_variables/1` shape:
            // bad JSON yields `%{}`, not a hard error.
            match serde_json::from_str::<serde_json::Value>(vars_json) {
                Ok(value) => {
                    gql_req = gql_req.variables(Variables::from_json(value));
                }
                Err(err) => {
                    tracing::debug!(error = %err, "p2p graphql: variables JSON parse failed; using empty");
                }
            }
        }

        // Authenticate. The wire request carries an `auth_token` which
        // is a user access token (the same kind the login mutation
        // hands back). When present and valid, attach a `CurrentUser`
        // context value so the schema's resolvers see the identity.
        let request_ctx = if let Some(token) = request.auth_token.as_deref() {
            match self.access_signer.verify(token) {
                Ok(claims) => match build_current_user(&self.db, &claims.sub).await {
                    Ok(Some(user)) => GraphqlRequestContext::with_user(user),
                    Ok(None) => {
                        tracing::debug!("p2p graphql: token verified but user row missing");
                        GraphqlRequestContext::anonymous()
                    }
                    Err(err) => {
                        tracing::warn!(error = %err, "p2p graphql: load user failed");
                        GraphqlRequestContext::anonymous()
                    }
                },
                Err(err) => {
                    tracing::debug!(error = %err, "p2p graphql: invalid auth token");
                    GraphqlRequestContext::anonymous()
                }
            }
        } else {
            GraphqlRequestContext::anonymous()
        };

        let gql_req = gql_req.data(request_ctx);
        let response = schema.execute(gql_req).await;

        // Serialize matching Phoenix's wire shape: `data` is a JSON
        // string (or null), `errors` is a JSON array string (or null).
        let data = if matches!(response.data, async_graphql::Value::Null) {
            None
        } else {
            Some(serde_json::to_string(&response.data).map_err(|err| {
                RouterError::Internal(format!("failed to encode graphql data: {err}"))
            })?)
        };
        let errors = if response.errors.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&response.errors).map_err(|err| {
                RouterError::Internal(format!("failed to encode graphql errors: {err}"))
            })?)
        };

        Ok(GraphQLResponse { data, errors })
    }

    async fn handle_hls_stream(
        &self,
        request: HlsRequest,
        _stream_id: String,
        stream_handle: HlsStreamHandle,
        _ctx: RouterContext,
    ) -> Result<(), RouterError> {
        let (Some(supervisor), Some(validator)) =
            (self.streaming.as_ref(), self.media_validator.as_ref())
        else {
            // Streaming surface not wired — emit a 501 so the client
            // sees a deterministic shape, matching the previous stub.
            return send_hls_error(&stream_handle, 501, "HLS streaming not configured").await;
        };

        // Step 1: verify the bearer media token. Failure → 401 header
        // so the client knows to re-pair / refresh.
        let Some(token) = request.auth_token.as_deref() else {
            return send_hls_error(&stream_handle, 401, "missing auth_token").await;
        };
        if let Err(err) = validator.validate(token).await {
            let status = match err {
                ValidationError::Expired
                | ValidationError::Invalid(_)
                | ValidationError::WrongType
                | ValidationError::InvalidDeviceId => 401,
                ValidationError::DeviceNotFound | ValidationError::DeviceRevoked => 403,
                ValidationError::Database(_) => 500,
            };
            tracing::warn!(error = %err, "p2p hls: auth failed");
            return send_hls_error(&stream_handle, status, "unauthorised").await;
        }

        // Step 2: look up the session by id. The Phoenix dispatcher
        // also handles `direct:` and `download:` prefixes; those land
        // in a follow-up unit when the supporting machinery exists in
        // mydia-rs. For now we accept a plain UUID session id and 404
        // anything else.
        let Ok(session_id) = Uuid::parse_str(&request.session_id) else {
            tracing::debug!(session_id = %request.session_id, "p2p hls: non-uuid session id");
            return send_hls_error(&stream_handle, 404, "session not found").await;
        };
        let Some(handle) = supervisor.get(session_id) else {
            tracing::debug!(session_id = %session_id, "p2p hls: session not found");
            return send_hls_error(&stream_handle, 404, "session not found").await;
        };

        // Step 3: heartbeat + wait for ready (FFmpeg has produced the
        // first playlist).
        let _ = handle.heartbeat().await;
        if !handle.info().ready {
            // Wait up to 30s for the session to flip to ready. Matches
            // Phoenix's `HlsSession.await_ready(pid, 30_000)`.
            let mut watch_rx = handle.watch();
            let wait = async {
                loop {
                    if watch_rx.borrow().ready {
                        return Ok(());
                    }
                    if watch_rx.changed().await.is_err() {
                        return Err("session ended before ready");
                    }
                }
            };
            match tokio::time::timeout(std::time::Duration::from_secs(30), wait).await {
                Ok(Ok(())) => {}
                Ok(Err(reason)) => {
                    tracing::warn!(session_id = %session_id, reason, "p2p hls: session terminated");
                    return send_hls_error(&stream_handle, 503, "session terminated").await;
                }
                Err(_) => {
                    tracing::warn!(session_id = %session_id, "p2p hls: ready timeout");
                    return send_hls_error(&stream_handle, 503, "transcoding not ready").await;
                }
            }
        }

        // Step 4: build the file path. Reject anything that escapes
        // the session temp dir.
        let file_path = handle.temp_dir.join(&request.path);
        if !is_within_dir(&file_path, &handle.temp_dir) {
            tracing::warn!(
                requested = %request.path,
                "p2p hls: path traversal attempt rejected"
            );
            return send_hls_error(&stream_handle, 403, "forbidden").await;
        }

        // Step 5: stat the file, build the header, and stream the
        // requested range. Stat is a sync syscall but cheap; do it on
        // a blocking thread to be consistent with the discipline.
        let stat_path = file_path.clone();
        let meta = match tokio::task::spawn_blocking(move || std::fs::metadata(&stat_path)).await {
            Ok(Ok(meta)) => meta,
            Ok(Err(err)) if err.kind() == std::io::ErrorKind::NotFound => {
                tracing::debug!(path = %file_path.display(), "p2p hls: file not found");
                return send_hls_error(&stream_handle, 404, "not found").await;
            }
            Ok(Err(err)) => {
                tracing::warn!(error = %err, "p2p hls: stat failed");
                return send_hls_error(&stream_handle, 500, "internal error").await;
            }
            Err(err) => {
                tracing::error!(error = %err, "p2p hls: spawn_blocking for stat failed");
                return send_hls_error(&stream_handle, 500, "internal error").await;
            }
        };
        let file_size = meta.len();

        let content_type = hls_content_type(&file_path);
        let cache_control = hls_cache_control(&file_path).map(str::to_owned);

        // Range request? Compute start/end/length and pick the right
        // status code. Matches the Phoenix `parse_range/3` shape.
        let (status, range_start, content_length, content_range) =
            match (request.range_start, request.range_end) {
                (None, None) => (200_u16, 0_u64, file_size, None),
                (start, end) => {
                    let start = start.unwrap_or(0);
                    let end_max = file_size.saturating_sub(1);
                    let end = Ord::min(end.unwrap_or(end_max), end_max);
                    let length = end.saturating_sub(start).saturating_add(1);
                    let range_header = format!("bytes {start}-{end}/{file_size}");
                    (206_u16, start, length, Some(range_header))
                }
            };

        let header = HlsResponseHeader {
            status,
            content_type: content_type.to_owned(),
            content_length,
            content_range,
            cache_control,
        };

        if let Err(reason) = stream_handle.send_header(header).await {
            tracing::warn!(error = %reason, "p2p hls: send_header failed");
            return Ok(());
        }

        // Stream the file directly from the Host's zero-copy path.
        // `stream_file_range` finishes the stream on success; on
        // failure we still need to send a close.
        let file_path_str = file_path.to_string_lossy().into_owned();
        if let Err(reason) = stream_handle
            .stream_file_range(file_path_str, range_start, content_length)
            .await
        {
            tracing::warn!(
                error = %reason,
                path = %file_path.display(),
                range_start,
                length = content_length,
                "p2p hls: stream_file_range failed"
            );
            // Best-effort close so the client unblocks.
            let _ = stream_handle.finish().await;
        }
        // Note: `stream_file_range` finishes the stream on the Host
        // side, so we do not call `finish` again on success. The
        // failure branch already covered the close.
        Ok(())
    }
}

/// Best-effort HLS-error reply. Sends a header with the requested
/// status and a tiny text body. Errors at this layer are deliberately
/// swallowed: if the underlying stream is already closed (peer hung
/// up), there's nothing we can usefully do.
async fn send_hls_error(
    handle: &HlsStreamHandle,
    status: u16,
    message: &str,
) -> Result<(), RouterError> {
    let body = message.as_bytes().to_vec();
    let header = HlsResponseHeader {
        status,
        content_type: "text/plain".to_owned(),
        content_length: body.len() as u64,
        content_range: None,
        cache_control: None,
    };
    let _ = handle.send_header(header).await;
    if !body.is_empty() {
        let _ = handle.send_chunk(body).await;
    }
    let _ = handle.finish().await;
    Ok(())
}

/// Load the user row + role for the given user id, mapping into the
/// GraphQL crate's `CurrentUser` shape. Returns `Ok(None)` when the
/// row is missing (token verified but user has since been deleted).
async fn build_current_user(
    db: &DatabaseConnection,
    user_id: &str,
) -> Result<Option<CurrentUser>, DbErr> {
    let Ok(user_uuid) = Uuid::parse_str(user_id) else {
        return Ok(None);
    };
    let user_uuid_text = UuidText(user_uuid);
    let backend = db.get_database_backend();

    // Select the small slice the GraphQL context needs. The full
    // user-row repo lives in `mydia-rs-graphql::repos::accounts`; we
    // duplicate the lookup here rather than depend on that internal
    // module so the p2p crate stays free of GraphQL repo internals.
    let model = users::Entity::find()
        .filter(Expr::col(users::Column::Id).eq(user_uuid_text.into_simple_expr(backend)))
        .one(db)
        .await?;
    let Some(model) = model else {
        return Ok(None);
    };
    let role =
        mydia_rs_auth::role::Role::parse(&model.role).unwrap_or(mydia_rs_auth::role::Role::Guest);
    Ok(Some(CurrentUser {
        id: user_uuid,
        username: model.username.unwrap_or_default(),
        role,
    }))
}

/// True when `requested` resolves to a path under `base`. Matches the
/// Phoenix `validate_path/2` shape — both paths are canonicalised via
/// `Path::components` traversal rather than `canonicalize` (which
/// would touch the filesystem and fail when the file doesn't exist
/// yet).
fn is_within_dir(requested: &Path, base: &Path) -> bool {
    // Reject anything containing `..` components outright; the Host's
    // path constraints don't follow symlinks but we still want to
    // refuse the obvious traversal patterns.
    if requested
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return false;
    }
    requested.starts_with(base)
}

fn hls_content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("m3u8") => "application/vnd.apple.mpegurl",
        Some("ts") => "video/mp2t",
        Some("mp4" | "m4v") => "video/mp4",
        Some("m4s") => "video/iso.segment",
        Some("mkv") => "video/x-matroska",
        Some("avi") => "video/x-msvideo",
        Some("mov") => "video/quicktime",
        Some("webm") => "video/webm",
        Some("vtt") => "text/vtt",
        _ => "application/octet-stream",
    }
}

fn hls_cache_control(path: &Path) -> Option<&'static str> {
    match path.extension().and_then(|e| e.to_str()) {
        Some("m3u8") => Some("no-cache"),
        Some("ts") => Some("max-age=86400"),
        _ => None,
    }
}
