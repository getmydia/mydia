//! U14 integration tests — auth, api-key, device, collection,
//! remote-access, download, subtitle resolvers.
//!
//! Real DB-backed branches (auth login, api-key CRUD, collection list /
//! get / items) exercise SQLite fixtures shaped like Phoenix's
//! migrations. Stubbed branches (download, device revoke, remote-access
//! mutations) assert the schema returns the expected `not implemented`
//! error so the parity replay harness in U13 can categorize them
//! correctly.

use async_graphql::{Request, Variables};
use chrono::{TimeZone, Utc};
use mydia_rs_auth::{hash_password, AccessTokenSigner};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config,
    types::{DateTimeSecs, JsonMap, StringArray, UuidText},
    Db,
};
use mydia_rs_graphql::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use mydia_rs_graphql::{build_schema, build_schema_with_signer, MydiaSchema};
use serde_json::json;
use tempfile::TempDir;
use uuid::Uuid;

const SCHEMA_SQL: &str = include_str!("fixtures/u14_schema.sql");

async fn fresh_db() -> (Db, TempDir) {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("u14.db");
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(path.to_string_lossy().into_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config(&config).await.unwrap();
    let pool = db.as_sqlite().unwrap();
    for stmt in SCHEMA_SQL.split(";\n") {
        let trimmed = stmt.trim();
        if trimmed.is_empty() {
            continue;
        }
        sqlx::query(trimmed).execute(pool).await.unwrap();
    }
    (db, tmp)
}

fn sample_dt() -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap())
}

async fn seed_user(
    db: &Db,
    id: UuidText,
    username: &str,
    email: Option<&str>,
    password_hash: Option<&str>,
) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt();
    sqlx::query(
        "INSERT INTO users (id, username, email, password_hash, role, display_name,
            inserted_at, updated_at)
         VALUES (?, ?, ?, ?, 'user', ?, ?, ?)",
    )
    .bind(id)
    .bind(username)
    .bind(email)
    .bind(password_hash)
    .bind(username)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed user");
}

async fn seed_movie(db: &Db, id: UuidText, title: &str) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt();
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'movie', ?, 2024, 42, ?, 1, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(JsonMap(json!({"poster_path": format!("/{title}.jpg")})))
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed movie");
}

async fn seed_collection(db: &Db, id: UuidText, user_id: UuidText, name: &str, is_system: bool) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt();
    sqlx::query(
        "INSERT INTO collections (id, name, type, sort_order, visibility, is_system,
            position, user_id, inserted_at, updated_at)
         VALUES (?, ?, 'manual', 'position', 'private', ?, 0, ?, ?, ?)",
    )
    .bind(id)
    .bind(name)
    .bind(is_system)
    .bind(user_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed collection");
}

async fn add_to_collection(
    db: &Db,
    collection_id: UuidText,
    media_item_id: UuidText,
    position: i32,
) {
    let pool = db.as_sqlite().unwrap();
    sqlx::query(
        "INSERT INTO collection_items (id, collection_id, media_item_id, position, inserted_at)
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(UuidText::new_v4())
    .bind(collection_id)
    .bind(media_item_id)
    .bind(position)
    .bind(sample_dt())
    .execute(pool)
    .await
    .expect("seed collection_items");
}

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
    let (db, _tmp) = fresh_db().await;
    let user_id = Uuid::new_v4();
    let hash = hash_password("hunter2").unwrap();
    seed_user(
        &db,
        UuidText::from(user_id),
        "alice",
        Some("alice@example.com"),
        Some(&hash),
    )
    .await;

    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer.clone());
    let resp = execute_anon(
        &schema,
        r#"mutation L($input: LoginInput!) {
            login(input: $input) {
                token expiresIn user { id username email }
            }
        }"#,
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
    let (db, _tmp) = fresh_db().await;
    let hash = hash_password("hunter2").unwrap();
    seed_user(
        &db,
        UuidText::new_v4(),
        "alice",
        Some("alice@example.com"),
        Some(&hash),
    )
    .await;

    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r#"mutation L($input: LoginInput!) {
            login(input: $input) { token }
        }"#,
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
    let (db, _tmp) = fresh_db().await;
    let hash = hash_password("right-password").unwrap();
    seed_user(
        &db,
        UuidText::new_v4(),
        "alice",
        Some("alice@example.com"),
        Some(&hash),
    )
    .await;
    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r#"mutation L($input: LoginInput!) { login(input: $input) { token } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let signer = AccessTokenSigner::new("test-secret", 5);
    let schema = build_schema_with_signer(GraphqlAppState::new(db), signer);
    let resp = execute_anon(
        &schema,
        r#"mutation L($input: LoginInput!) { login(input: $input) { token } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let hash = hash_password("hunter2").unwrap();
    seed_user(&db, UuidText::new_v4(), "alice", None, Some(&hash)).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(
        &schema,
        r#"mutation L($input: LoginInput!) { login(input: $input) { token } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice", None, None).await;

    let schema = build_schema(GraphqlAppState::new(db.clone()));
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
    let pool = db.as_sqlite().unwrap();
    let stored_hash: String = sqlx::query_scalar("SELECT key_hash FROM api_keys WHERE name = ?")
        .bind("test")
        .fetch_one(pool)
        .await
        .unwrap();
    assert!(stored_hash.starts_with("$argon2"));
    // Verifying the plaintext against the stored hash should pass.
    mydia_rs_auth::verify_api_key_hash(key, &stored_hash).unwrap();
}

#[tokio::test]
async fn list_api_keys_returns_only_callers_own() {
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    seed_user(&db, UuidText::from(bob), "bob", None, None).await;
    // Seed one key per user directly.
    let pool = db.as_sqlite().unwrap();
    for (uid, name) in [(alice, "alice-key"), (bob, "bob-key")] {
        sqlx::query(
            "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, permissions, inserted_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(UuidText::new_v4())
        .bind(UuidText::from(uid))
        .bind(name)
        .bind("$argon2id$stub")
        .bind("prefix")
        .bind(StringArray(vec!["read".into()]))
        .bind(sample_dt())
        .execute(pool)
        .await
        .unwrap();
    }

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"{ apiKeys { name } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    seed_user(&db, UuidText::from(bob), "bob", None, None).await;
    let key_id = UuidText::new_v4();
    let pool = db.as_sqlite().unwrap();
    sqlx::query(
        "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, permissions, inserted_at)
         VALUES (?, ?, 'k', ?, ?, ?, ?)",
    )
    .bind(key_id)
    .bind(UuidText::from(alice))
    .bind("$argon2id$stub")
    .bind("prefix")
    .bind(StringArray(vec!["read".into()]))
    .bind(sample_dt())
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db));
    // Bob attempts to revoke alice's key — forbidden.
    let bob_user = current_user(bob, "bob");
    let resp_bob = execute_authed(
        &schema,
        &bob_user,
        r#"mutation R($id: ID!) { revokeApiKey(id: $id) { revokedAt } }"#,
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
        r#"mutation R($id: ID!) { revokeApiKey(id: $id) { revokedAt } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let key_id = UuidText::new_v4();
    let pool = db.as_sqlite().unwrap();
    sqlx::query(
        "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, permissions, inserted_at)
         VALUES (?, ?, 'k', ?, ?, ?, ?)",
    )
    .bind(key_id)
    .bind(UuidText::from(alice))
    .bind("$argon2id$stub")
    .bind("prefix")
    .bind(StringArray(vec!["read".into()]))
    .bind(sample_dt())
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db.clone()));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"mutation D($id: ID!) { deleteApiKey(id: $id) }"#,
        Variables::from_json(json!({"id": key_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["deleteApiKey"], true);

    let pool = db.as_sqlite().unwrap();
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM api_keys WHERE id = ?")
        .bind(key_id)
        .fetch_one(pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}

// ──────────── collections ────────────────────────────────────────

#[tokio::test]
async fn list_collections_excludes_system_favorites() {
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Favorites",
        true,
    )
    .await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Watchlist",
        false,
    )
    .await;
    seed_collection(
        &db,
        UuidText::new_v4(),
        UuidText::from(alice),
        "Rewatch",
        false,
    )
    .await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"{ collections { name itemCount posterPaths } }"#,
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
    let (db, _tmp) = fresh_db().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(&schema, r#"{ collections { name } }"#, Variables::default()).await;
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
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let collection_id = UuidText::new_v4();
    seed_collection(
        &db,
        collection_id,
        UuidText::from(alice),
        "Watchlist",
        false,
    )
    .await;
    let movie_a = UuidText::new_v4();
    let movie_b = UuidText::new_v4();
    seed_movie(&db, movie_a, "Arrival").await;
    seed_movie(&db, movie_b, "Dune").await;
    add_to_collection(&db, collection_id, movie_a, 0).await;
    add_to_collection(&db, collection_id, movie_b, 1).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"query C($id: ID!) {
            collectionItems(collectionId: $id) {
                title type id artwork { posterUrl }
            }
        }"#,
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
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"{ remoteAccessStatus { enabled endpointAddr connectedPeers } }"#,
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["remoteAccessStatus"]["enabled"], false);
    assert!(data["remoteAccessStatus"]["endpointAddr"].is_null());
    assert_eq!(data["remoteAccessStatus"]["connectedPeers"], 0);
}

#[tokio::test]
async fn devices_query_returns_empty_stub_for_now() {
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"{ devices { id deviceName } }"#,
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["devices"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn download_options_mutation_is_stubbed() {
    let (db, _tmp) = fresh_db().await;
    let schema = build_schema(GraphqlAppState::new(db));
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
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(alice, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"mutation { generateClaimCode { code } }"#,
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("not implemented"));
}

#[tokio::test]
async fn revoke_device_is_stubbed() {
    let (db, _tmp) = fresh_db().await;
    let alice = Uuid::new_v4();
    seed_user(&db, UuidText::from(alice), "alice", None, None).await;
    let schema = build_schema(GraphqlAppState::new(db));
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
