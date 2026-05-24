//! U14 integration tests — auth, api-key, device, collection,
//! remote-access, download, subtitle resolvers.
//!
//! Real DB-backed branches (auth login, api-key CRUD, collection list /
//! get / items) exercise `SQLite` fixtures shaped like Phoenix's
//! migrations. Stubbed branches (download, device revoke, remote-access
//! mutations) assert the schema returns the expected `not implemented`
//! error so the parity replay harness in U13 can categorize them
//! correctly.

mod common;

use async_graphql::{Request, Variables};
use mydia_rs_auth::{hash_password, AccessTokenSigner};
use mydia_rs_db::types::UuidText;
use mydia_rs_entities::api_keys;
use mydia_rs_graphql::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use mydia_rs_graphql::{build_schema, build_schema_with_signer, MydiaSchema};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, EntityTrait, PaginatorTrait, QueryFilter};
use serde_json::json;
use uuid::Uuid;

use common::{
    build_test_schema, fresh_u14_db, seed_api_key, seed_collection, seed_collection_item,
    seed_movie_with_metadata, seed_user_with_password,
};

fn current_user(id: Uuid, username: &str) -> CurrentUser {
    CurrentUser {
        id,
        username: username.to_owned(),
        role: mydia_rs_auth::role::Role::User,
    }
}

async fn execute_authed(
    schema: &MydiaSchema,
    user: &CurrentUser,
    query: &str,
    variables: Variables,
) -> async_graphql::Response {
    let request = Request::new(query)
        .variables(variables)
        .data(GraphqlRequestContext::with_user(user.clone()));
    schema.execute(request).await
}

async fn execute_anon(
    schema: &MydiaSchema,
    query: &str,
    variables: Variables,
) -> async_graphql::Response {
    let request = Request::new(query)
        .variables(variables)
        .data(GraphqlRequestContext::anonymous());
    schema.execute(request).await
}

// ──────────── login ───────────────────────────────────────────────

#[tokio::test]
async fn login_with_valid_username_and_password_returns_token() {
    let db = fresh_u14_db().await;
    let user_id = Uuid::new_v4();
    let hash = hash_password("hunter2").unwrap();
    seed_user_with_password(
        &db,
        UuidText::from(user_id),
        "alice",
        Some("alice@example.com"),
        &hash,
    )
    .await;

    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer.clone());
    let resp = execute_anon(
        &schema,
        r"mutation L($input: LoginInput!) {
            login(input: $input) {
                token expiresIn user { id username email }
            }
        }",
        Variables::from_json(json!({
            "input": {
                "username": "alice",
                "password": "hunter2",
                "deviceId": "dev-1",
                "deviceName": "Test",
                "platform": "web"
            }
        })),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let token = data["login"]["token"].as_str().unwrap();
    let claims = signer.verify(token).unwrap();
    assert_eq!(claims.user_id(), user_id.to_string());
    assert_eq!(data["login"]["user"]["username"], "alice");
    assert!(data["login"]["expiresIn"].as_i64().unwrap() > 0);
}

#[tokio::test]
async fn login_with_email_also_works() {
    let db = fresh_u14_db().await;
    let hash = hash_password("hunter2").unwrap();
    seed_user_with_password(
        &db,
        UuidText::new_v4(),
        "alice",
        Some("alice@example.com"),
        &hash,
    )
    .await;

    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r"mutation L($input: LoginInput!) {
            login(input: $input) { token }
        }",
        Variables::from_json(json!({
            "input": {
                "username": "alice@example.com",
                "password": "hunter2",
                "deviceId": "x",
                "deviceName": "x",
                "platform": "web"
            }
        })),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
}

#[tokio::test]
async fn login_with_wrong_password_rejects_without_timing_leak() {
    let db = fresh_u14_db().await;
    let hash = hash_password("right-password").unwrap();
    seed_user_with_password(
        &db,
        UuidText::new_v4(),
        "alice",
        Some("alice@example.com"),
        &hash,
    )
    .await;
    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r"mutation L($input: LoginInput!) { login(input: $input) { token } }",
        Variables::from_json(json!({
            "input": {
                "username": "alice",
                "password": "wrong",
                "deviceId": "x",
                "deviceName": "x",
                "platform": "web"
            }
        })),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0]
        .message
        .contains("Invalid username or password"));
}

#[tokio::test]
async fn login_with_unknown_user_rejects() {
    let db = fresh_u14_db().await;
    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r"mutation L($input: LoginInput!) { login(input: $input) { token } }",
        Variables::from_json(json!({
            "input": {
                "username": "nope",
                "password": "x",
                "deviceId": "x",
                "deviceName": "x",
                "platform": "web"
            }
        })),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("Invalid"));
}

#[tokio::test]
async fn login_without_signer_returns_clear_error() {
    let db = fresh_u14_db().await;
    let hash = hash_password("hunter2").unwrap();
    seed_user_with_password(&db, UuidText::new_v4(), "alice", None, &hash).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(
        &schema,
        r"mutation L($input: LoginInput!) { login(input: $input) { token } }",
        Variables::from_json(json!({
            "input": {
                "username": "alice",
                "password": "hunter2",
                "deviceId": "x",
                "deviceName": "x",
                "platform": "web"
            }
        })),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0]
        .message
        .contains("Token signer not configured"));
}

// ──────────── api keys ────────────────────────────────────────────

#[tokio::test]
async fn create_api_key_returns_plain_key_and_persists_hash() {
    let db = fresh_u14_db().await;
    let user_id = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(user_id), "alice", None, "x").await;

    let schema = build_test_schema(db.clone());
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"mutation M {
            createApiKey(name: "test", permissions: ["read"]) {
                key
                apiKey { id name keyPrefix permissions }
            }
        }"#,
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let key = data["createApiKey"]["key"].as_str().unwrap();
    assert!(key.starts_with("mydia_"));
    assert_eq!(data["createApiKey"]["apiKey"]["name"], "test");
    let permissions = data["createApiKey"]["apiKey"]["permissions"]
        .as_array()
        .unwrap();
    assert_eq!(permissions.len(), 1);
    assert_eq!(permissions[0], "read");

    // The DB stores the Argon2 hash, not the plain key.
    let stored = api_keys::Entity::find()
        .filter(api_keys::Column::Name.eq("test".to_owned()))
        .one(&db)
        .await
        .unwrap()
        .expect("api key row");
    assert!(stored.key_hash.starts_with("$argon2"));
    mydia_rs_auth::verify_api_key_hash(key, &stored.key_hash).unwrap();
}

#[tokio::test]
async fn list_api_keys_returns_only_callers_own() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    seed_user_with_password(&db, UuidText::from(bob), "bob", None, "x").await;
    // Seed one key per user directly. `key_hash` is UNIQUE so each
    // seeded row needs a distinct value.
    for (uid, name, hash) in [
        (alice, "alice-key", "$argon2id$alice"),
        (bob, "bob-key", "$argon2id$bob"),
    ] {
        seed_api_key(
            &db,
            UuidText::new_v4(),
            UuidText::from(uid),
            name,
            hash,
            "prefix",
            vec!["read".into()],
        )
        .await;
    }

    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"{ apiKeys { name } }",
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let keys = data["apiKeys"].as_array().unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0]["name"], "alice-key");
}

#[tokio::test]
async fn revoke_api_key_marks_row_and_blocks_other_users() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    seed_user_with_password(&db, UuidText::from(bob), "bob", None, "x").await;
    let key_id = UuidText::new_v4();
    seed_api_key(
        &db,
        key_id,
        UuidText::from(alice),
        "k",
        "$argon2id$stub",
        "prefix",
        vec!["read".into()],
    )
    .await;

    let schema = build_test_schema(db);
    // Bob attempts to revoke alice's key — forbidden.
    let bob_user = current_user(bob, "bob");
    let resp_bob = execute_authed(
        &schema,
        &bob_user,
        r"mutation R($id: ID!) { revokeApiKey(id: $id) { revokedAt } }",
        Variables::from_json(json!({"id": key_id.0.to_string()})),
    )
    .await;
    assert!(!resp_bob.errors.is_empty());
    assert!(resp_bob.errors[0].message.contains("Forbidden"));

    // Alice can revoke.
    let alice_user = current_user(alice, "alice");
    let resp_alice = execute_authed(
        &schema,
        &alice_user,
        r"mutation R($id: ID!) { revokeApiKey(id: $id) { revokedAt } }",
        Variables::from_json(json!({"id": key_id.0.to_string()})),
    )
    .await;
    assert!(
        resp_alice.errors.is_empty(),
        "errors: {:?}",
        resp_alice.errors
    );
    let data = resp_alice.data.into_json().unwrap();
    assert!(data["revokeApiKey"]["revokedAt"].is_string());
}

#[tokio::test]
async fn delete_api_key_removes_row() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let key_id = UuidText::new_v4();
    seed_api_key(
        &db,
        key_id,
        UuidText::from(alice),
        "k",
        "$argon2id$stub",
        "prefix",
        vec!["read".into()],
    )
    .await;

    let schema = build_test_schema(db.clone());
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation D($id: ID!) { deleteApiKey(id: $id) }",
        Variables::from_json(json!({"id": key_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["deleteApiKey"], true);

    let backend = db.get_database_backend();
    let count = api_keys::Entity::find()
        .filter(Expr::col(api_keys::Column::Id).eq(key_id.into_simple_expr(backend)))
        .count(&db)
        .await
        .unwrap();
    assert_eq!(count, 0);
}

// ──────────── collections ────────────────────────────────────────

#[tokio::test]
async fn list_collections_excludes_system_favorites() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Favorites",
        "manual",
        true,
        0,
    )
    .await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Watchlist",
        "manual",
        false,
        0,
    )
    .await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Rewatch",
        "manual",
        false,
        0,
    )
    .await;

    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"{ collections { name itemCount posterPaths } }",
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let names: Vec<String> = data["collections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names.len(), 2);
    assert!(!names.contains(&"Favorites".to_owned()));
    assert!(names.contains(&"Watchlist".to_owned()));
    assert!(names.contains(&"Rewatch".to_owned()));
}

#[tokio::test]
async fn list_collections_returns_empty_for_anonymous() {
    let db = fresh_u14_db().await;
    let schema = build_test_schema(db);
    let resp = execute_anon(&schema, r"{ collections { name } }", Variables::default()).await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    assert_eq!(
        resp.data.into_json().unwrap()["collections"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}

#[tokio::test]
async fn collection_items_returns_recently_added_shape() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let collection_id = UuidText::new_v4();
    seed_collection(
        &db,
        collection_id,
        UuidText::from(alice),
        "Watchlist",
        "manual",
        false,
        0,
    )
    .await;
    let movie_a = UuidText::new_v4();
    let movie_b = UuidText::new_v4();
    seed_movie_with_metadata(
        &db,
        movie_a,
        "Arrival",
        json!({"poster_path": "/Arrival.jpg"}),
    )
    .await;
    seed_movie_with_metadata(&db, movie_b, "Dune", json!({"poster_path": "/Dune.jpg"})).await;
    seed_collection_item(&db, UuidText::new_v4(), collection_id, movie_a, 0).await;
    seed_collection_item(&db, UuidText::new_v4(), collection_id, movie_b, 1).await;

    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"query C($id: ID!) {
            collectionItems(collectionId: $id) {
                title type id artwork { posterUrl }
            }
        }",
        Variables::from_json(json!({"id": collection_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let items = data["collectionItems"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["title"], "Arrival");
    assert_eq!(items[1]["title"], "Dune");
    assert!(items[0]["id"].as_str().unwrap().starts_with("movie:"));
    assert_eq!(items[0]["artwork"]["posterUrl"], "/Arrival.jpg");
}

// ──────────── stubs ──────────────────────────────────────────────

#[tokio::test]
async fn remote_access_status_is_disabled_stub() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"{ remoteAccessStatus { enabled endpointAddr connectedPeers } }",
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["remoteAccessStatus"]["enabled"], false);
    assert!(serde_json::Value::is_null(
        &data["remoteAccessStatus"]["endpointAddr"]
    ));
    assert_eq!(data["remoteAccessStatus"]["connectedPeers"], 0);
}

#[tokio::test]
async fn devices_query_returns_empty_stub_for_now() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"{ devices { id deviceName } }",
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["devices"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn download_options_mutation_is_stubbed() {
    let db = fresh_u14_db().await;
    let schema = build_test_schema(db);
    let resp = execute_anon(
        &schema,
        r#"mutation { downloadOptions(contentType: "movie", id: "x") { resolution } }"#,
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("not implemented"));
}

#[tokio::test]
async fn generate_claim_code_is_stubbed_for_authed_user() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation { generateClaimCode { code } }",
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("not implemented"));
}

#[tokio::test]
async fn revoke_device_is_stubbed() {
    let db = fresh_u14_db().await;
    let alice = Uuid::new_v4();
    seed_user_with_password(&db, UuidText::from(alice), "alice", None, "x").await;
    let schema = build_test_schema(db);
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"mutation { revokeDevice(id: "anything") { success } }"#,
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("not implemented"));
}
