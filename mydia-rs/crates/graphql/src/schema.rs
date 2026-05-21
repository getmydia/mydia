//! Root Query / Mutation / Subscription types.
//!
//! Today the roots are minimal stubs: a `__typename`-bearing root that
//! exposes a `schemaVersion` field. The actual resolver families ship
//! in later units (browse + discovery + media-detail at U10,
//! search + streaming + playback mutations at U11, subscriptions at
//! U12, remaining resolvers at U14).
//!
//! The shape here is deliberately the boring one — every later unit
//! adds methods to these structs rather than restructuring the root.

use async_graphql::{EmptySubscription, Object, Schema, SchemaBuilder, ID};

use crate::context::GraphqlAppState;
use crate::node_id::NodeId;

/// Root Query type.
///
/// Resolver units (U10, U11, U14) extend this via additional `impl`
/// blocks; async-graphql merges them at schema-build time. The
/// `name = "Query"` rename matches the Absinthe shape — Relay
/// clients look for a top-level `Query` type by name, not
/// `QueryRoot`.
pub struct QueryRoot;

#[Object(name = "Query")]
impl QueryRoot {
    /// Stable string identifying the GraphQL schema build. Useful for
    /// the parity replay harness in U13 and for smoke tests asserting
    /// the schema is wired correctly.
    async fn schema_version(&self) -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    /// Decode a global ID and report its type tag, without resolving
    /// the underlying node. The concrete `node(id: ID!): Node` field
    /// that returns the polymorphic type lands in U10 alongside the
    /// first node-implementing types; until then, this is the
    /// smoke-test entry point that exercises [`NodeId::decode`] over
    /// the GraphQL surface.
    ///
    /// Returns `null` for malformed IDs (mirrors Phoenix's
    /// `BrowseResolver.get_node/3` returning `{:error, :invalid_node_id}`,
    /// surfaced as a top-level error in U10).
    async fn node_type(&self, id: ID) -> Option<String> {
        NodeId::decode(id.as_str())
            .ok()
            .map(|n| n.type_tag().to_owned())
    }
}

/// Root Mutation type. Populated in U11+ (playback, streaming, auth,
/// API keys, devices, downloads, remote access).
pub struct MutationRoot;

#[Object(name = "Mutation")]
impl MutationRoot {
    /// Mutations land in U11+. This placeholder keeps the root
    /// non-empty (async-graphql requires at least one field on
    /// each registered type) and asserts the mutation pipeline
    /// is wired through to the schema builder.
    async fn ping(&self) -> &'static str {
        "pong"
    }
}

/// The wired schema type alias resolvers and the axum handler
/// reference. Subscriptions land in U12; until then,
/// [`EmptySubscription`] keeps the WebSocket endpoint healthy
/// without registering any subscription fields.
pub type MydiaSchema = Schema<QueryRoot, MutationRoot, EmptySubscription>;

/// Build the schema with the supplied long-lived state attached.
///
/// Per-request data (CurrentUser, anything depending on the inbound
/// HTTP request) is attached by the axum handler via
/// `async_graphql::Request::data`, not here.
pub fn build_schema(state: GraphqlAppState) -> MydiaSchema {
    schema_builder(state).finish()
}

/// Lower-level builder hook — exposed so the parity harness (U13) and
/// future units can register additional middleware or data slots
/// before finishing the schema.
pub fn schema_builder(
    state: GraphqlAppState,
) -> SchemaBuilder<QueryRoot, MutationRoot, EmptySubscription> {
    Schema::build(QueryRoot, MutationRoot, EmptySubscription).data(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a schema without any DB connection — the root-level
    /// smoke tests don't touch the pool.
    fn schema_for_tests() -> MydiaSchema {
        Schema::build(QueryRoot, MutationRoot, EmptySubscription).finish()
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
        // schema_version → schemaVersion conversion is async-graphql's
        // default; this asserts it explicitly because the plan's U8
        // test scenarios call it out as a load-bearing behavior.
        let schema = schema_for_tests();
        let response = schema.execute("{ snake: schemaVersion }").await;
        assert!(response.errors.is_empty());
        // The query above uses an alias proving the camelCased name
        // is what the server accepts; a query for `{ schema_version }`
        // would fail with "unknown field".
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
        assert!(!sdl.is_empty());
        assert!(sdl.contains("type Query"));
        assert!(sdl.contains("type Mutation"));
        assert!(sdl.contains("schemaVersion"));
        // Defensive — the camelCase conversion lands here too.
        assert!(!sdl.contains("schema_version"));
    }

    #[test]
    fn node_ref_helpers_compile() {
        // Lightweight assertion that NodeRef integration with the
        // schema module is reachable. Concrete uses arrive in U10.
        let _ = crate::node_id::NodeRef::Int(1);
    }
}
