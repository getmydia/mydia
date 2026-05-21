//! U8 integration smoke tests.
//!
//! Asserts the load-bearing properties of the GraphQL surface:
//!
//! - The SDL exports cleanly and contains the expected root types and
//!   camelCase field names.
//! - `node_type` round-trips every encoded ID class.
//! - The axum router constructs without panic over the schema.
//! - Subscription endpoint registration via `EmptySubscription` does
//!   not fail at schema-build time (the WS protocol upgrade itself is
//!   covered by manual probes until U12 lands a real subscription).

use async_graphql::{EmptySubscription, Schema};
use mydia_rs_graphql::schema::{MutationRoot, QueryRoot};
use mydia_rs_graphql::{router, NodeId, NodeRef};

fn schema() -> Schema<QueryRoot, MutationRoot, EmptySubscription> {
    Schema::build(
        QueryRoot::default(),
        MutationRoot::default(),
        EmptySubscription,
    )
    .finish()
}

#[tokio::test]
async fn introspection_runs() {
    let schema = schema();
    let response = schema
        .execute("{ __schema { queryType { name } mutationType { name } } }")
        .await;
    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["__schema"]["queryType"]["name"], "Query");
    assert_eq!(data["__schema"]["mutationType"]["name"], "Mutation");
}

#[tokio::test]
async fn sdl_contains_expected_root_types() {
    let schema = schema();
    let sdl = schema.sdl();
    assert!(sdl.contains("type Query"));
    assert!(sdl.contains("type Mutation"));
    assert!(sdl.contains("schemaVersion"));
    assert!(sdl.contains("nodeType"));
    assert!(sdl.contains("ping"));
    // The plan calls out subscription endpoint registration; the
    // root subscription type lands in U12, but EmptySubscription
    // here should not leak a Subscription type into the SDL.
    assert!(!sdl.contains("type Subscription"));
}

#[tokio::test]
async fn node_type_resolves_all_node_kinds() {
    let schema = schema();
    let cases = [
        ("movie:42", "movie"),
        ("show:7", "show"),
        ("episode:99", "episode"),
        ("library:3", "library"),
        ("season:11:5", "season"),
    ];
    for (input, expected) in cases {
        let query = format!(r#"{{ nodeType(id: "{input}") }}"#);
        let response = schema.execute(&query).await;
        assert!(
            response.errors.is_empty(),
            "input {input}: errors: {:?}",
            response.errors
        );
        let data = response.data.into_json().unwrap();
        assert_eq!(
            data["nodeType"], expected,
            "input {input} should map to {expected}"
        );
    }
}

#[tokio::test]
async fn node_id_round_trips_uuid() {
    let original = NodeId::Movie(NodeRef::Str(
        "0186fa3d-9d57-7c1a-8c2e-1b0c5e6f7a8b".to_owned(),
    ));
    let encoded = original.encode();
    let decoded = NodeId::decode(&encoded).expect("decode");
    assert_eq!(decoded, original);
}

#[tokio::test]
async fn node_id_byte_parity_with_phoenix_shape() {
    // Pin the exact byte sequence Phoenix emits for known inputs.
    assert_eq!(NodeId::Movie(NodeRef::Int(42)).encode(), "movie:42");
    assert_eq!(NodeId::TvShow(NodeRef::Int(7)).encode(), "show:7");
    assert_eq!(NodeId::Episode(NodeRef::Int(99)).encode(), "episode:99");
    assert_eq!(NodeId::LibraryPath(NodeRef::Int(3)).encode(), "library:3");
    assert_eq!(
        NodeId::Season {
            show_id: NodeRef::Int(11),
            season_number: 5
        }
        .encode(),
        "season:11:5"
    );
}

#[tokio::test]
async fn axum_router_builds() {
    let _router = router(schema());
}
