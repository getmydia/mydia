//! Root Query / Mutation / Subscription types.
//!
//! The schema's actual `Query` type is a `MergedObject` composed of
//! one resolver struct per family — `IntrospectionQueries` (this
//! file), `BrowseQueries` (U10.a), `DiscoveryQueries` (U10.b),
//! `SearchQueries`/`StreamingQueries` (U11), and later units' own
//! structs. async-graphql merges them at schema-build time, so each
//! unit lands a new struct without touching this file beyond adding
//! it to the tuple.
//!
//! `MutationRoot` follows the same pattern with one merged struct per
//! mutation family.

use async_graphql::{MergedObject, Object, Schema, SchemaBuilder, ID};

use crate::context::GraphqlAppState;
use crate::mutations::api_key::ApiKeyMutations;
use crate::mutations::auth::AuthMutations;
use crate::mutations::device::DeviceMutations;
use crate::mutations::download::DownloadMutations;
use crate::mutations::playback::PlaybackMutations;
use crate::mutations::remote_access::RemoteAccessMutations;
use crate::mutations::streaming::StreamingMutations;
use crate::node_id::NodeId;
use crate::queries::api_key::ApiKeyQueries;
use crate::queries::browse::{resolve_node, BrowseQueries, NodeBlob};
use crate::queries::collection::CollectionQueries;
use crate::queries::device::DeviceQueries;
use crate::queries::discovery::DiscoveryQueries;
use crate::queries::remote_access::RemoteAccessQueries;
use crate::queries::search::SearchQueries;
use crate::queries::streaming::StreamingQueries;
use crate::subscriptions::SubscriptionRoot;

/// Introspection + utility queries that aren't tied to a specific
/// Phoenix resolver family.
pub struct IntrospectionQueries;

#[Object(name = "_Introspection")]
impl IntrospectionQueries {
    /// Stable string identifying the GraphQL schema build. Useful for
    /// the parity replay harness in U13 and for smoke tests asserting
    /// the schema is wired correctly.
    async fn schema_version(&self) -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    /// Decode a global ID and report its type tag, without resolving
    /// the underlying node. Convenience field for the parity harness
    /// — useful when a corpus record's `id` argument fails to round-
    /// trip and you want to know whether the encoding or the lookup
    /// is the culprit.
    async fn node_type(&self, id: ID) -> Option<String> {
        NodeId::decode(id.as_str())
            .ok()
            .map(|n| n.type_tag().to_owned())
    }

    /// Polymorphic node lookup — port of `BrowseResolver.get_node/3`.
    async fn node(
        &self,
        ctx: &async_graphql::Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<NodeBlob>> {
        resolve_node(ctx, id).await
    }
}

/// The merged Query root type. New resolver families add themselves
/// here as the corresponding U10/U11/U14 units land.
#[derive(MergedObject, Default)]
#[graphql(name = "Query")]
pub struct QueryRoot(
    IntrospectionQueries,
    BrowseQueries,
    DiscoveryQueries,
    SearchQueries,
    StreamingQueries,
    ApiKeyQueries,
    DeviceQueries,
    CollectionQueries,
    RemoteAccessQueries,
);

impl Default for IntrospectionQueries {
    fn default() -> Self {
        Self
    }
}

/// Placeholder mutation surface used until U14 lands its remaining
/// families. Kept separate so the future `ApiKeyMutations`,
/// `AuthMutations`, `DeviceMutations`, etc. can merge in without
/// modifying this struct.
pub struct IntrospectionMutations;

#[Object(name = "_IntrospectionMutation")]
impl IntrospectionMutations {
    /// Keeps the mutation root non-empty when the merged set has
    /// nothing else to expose (e.g. in U13's parity harness when it
    /// builds a schema without DB-backed resolvers). Once U14 lands
    /// `auth/api_key/device` mutations, this can be dropped.
    async fn ping(&self) -> &'static str {
        "pong"
    }
}

impl Default for IntrospectionMutations {
    fn default() -> Self {
        Self
    }
}

/// The merged Mutation root. Same convention as `QueryRoot`: one
/// struct per family.
#[derive(MergedObject, Default)]
#[graphql(name = "Mutation")]
pub struct MutationRoot(
    IntrospectionMutations,
    PlaybackMutations,
    StreamingMutations,
    AuthMutations,
    ApiKeyMutations,
    DeviceMutations,
    DownloadMutations,
    RemoteAccessMutations,
);

/// The wired schema type alias resolvers and the axum handler
/// reference.
pub type MydiaSchema = Schema<QueryRoot, MutationRoot, SubscriptionRoot>;

/// Build the schema with the supplied long-lived state attached.
pub fn build_schema(state: GraphqlAppState) -> MydiaSchema {
    schema_builder(state).finish()
}

/// Build the schema with state + a JWT signer for the `login`
/// mutation. The signer is optional; when omitted, `login` returns a
/// clear "Token signer not configured" error rather than silently
/// issuing tokens with a random key.
pub fn build_schema_with_signer(
    state: GraphqlAppState,
    signer: mydia_rs_auth::AccessTokenSigner,
) -> MydiaSchema {
    schema_builder(state).data(signer).finish()
}

/// Lower-level builder hook — exposed so the parity harness (U13) and
/// future units can register additional middleware or data slots
/// before finishing the schema.
pub fn schema_builder(
    state: GraphqlAppState,
) -> SchemaBuilder<QueryRoot, MutationRoot, SubscriptionRoot> {
    Schema::build(
        QueryRoot::default(),
        MutationRoot::default(),
        SubscriptionRoot,
    )
    .data(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a schema without any DB connection — the root-level
    /// smoke tests don't touch the pool. They cover the
    /// `IntrospectionQueries` portion only; `BrowseQueries` tests live
    /// in `tests/browse.rs` against a real `SQLite` fixture.
    fn schema_for_tests() -> MydiaSchema {
        Schema::build(
            QueryRoot::default(),
            MutationRoot::default(),
            SubscriptionRoot,
        )
        .finish()
    }

    #[tokio::test]
    async fn typename_query_returns_query() {
        let schema = schema_for_tests();
        let response = schema.execute("{ __typename }").await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert_eq!(data["__typename"], "Query");
    }

    #[tokio::test]
    async fn schema_version_resolves() {
        let schema = schema_for_tests();
        let response = schema.execute("{ schemaVersion }").await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert_eq!(data["schemaVersion"], env!("CARGO_PKG_VERSION"));
    }

    #[tokio::test]
    async fn snake_case_field_resolves_as_camel_case() {
        let schema = schema_for_tests();
        let response = schema.execute("{ snake: schemaVersion }").await;
        assert!(response.errors.is_empty());
        let bad = schema.execute("{ schema_version }").await;
        assert!(
            !bad.errors.is_empty(),
            "snake_case should not resolve at the request layer"
        );
    }

    #[tokio::test]
    async fn node_type_decodes_movie_id() {
        let schema = schema_for_tests();
        let response = schema.execute(r#"{ nodeType(id: "movie:42") }"#).await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert_eq!(data["nodeType"], "movie");
    }

    #[tokio::test]
    async fn node_type_decodes_season_composite_id() {
        let schema = schema_for_tests();
        let response = schema
            .execute(r#"{ nodeType(id: "season:abc-uuid:3") }"#)
            .await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert_eq!(data["nodeType"], "season");
    }

    #[tokio::test]
    async fn node_type_returns_null_for_invalid_id() {
        let schema = schema_for_tests();
        let response = schema
            .execute(r#"{ nodeType(id: "not-a-real-node-id") }"#)
            .await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert!(data["nodeType"].is_null());
    }

    #[tokio::test]
    async fn mutation_ping_responds_pong() {
        let schema = schema_for_tests();
        let response = schema.execute("mutation { ping }").await;
        assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
        let data = response.data.into_json().unwrap();
        assert_eq!(data["ping"], "pong");
    }

    #[test]
    fn schema_sdl_is_non_empty_and_parses() {
        let schema = schema_for_tests();
        let sdl = schema.sdl();
        assert!(sdl.contains("type Query"));
        assert!(sdl.contains("type Mutation"));
        assert!(sdl.contains("type Subscription"));
        assert!(sdl.contains("schemaVersion"));
        assert!(sdl.contains("movies"));
        assert!(sdl.contains("tvShows"));
        assert!(sdl.contains("search"));
        assert!(sdl.contains("streamingCandidates"));
        assert!(sdl.contains("updateMovieProgress"));
        assert!(sdl.contains("toggleFavorite"));
        assert!(sdl.contains("startStreamingSession"));
        assert!(sdl.contains("endStreamingSession"));
        assert!(sdl.contains("progressUpdated"));
        assert!(sdl.contains("deviceStatusChanged"));
        assert!(sdl.contains("login"));
        assert!(sdl.contains("createApiKey"));
        assert!(sdl.contains("revokeApiKey"));
        assert!(sdl.contains("deleteApiKey"));
        assert!(sdl.contains("revokeDevice"));
        assert!(sdl.contains("downloadOptions"));
        assert!(sdl.contains("prepareDownload"));
        assert!(sdl.contains("cancelDownloadJob"));
        assert!(sdl.contains("generateClaimCode"));
        assert!(sdl.contains("refreshMediaToken"));
        assert!(sdl.contains("apiKeys"));
        assert!(sdl.contains("devices"));
        assert!(sdl.contains("collections"));
        assert!(sdl.contains("remoteAccessStatus"));
        assert!(!sdl.contains("schema_version"));
    }
}
