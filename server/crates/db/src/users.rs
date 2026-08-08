use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct User {
    pub id: String,
    pub username: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub password_hash: String,
    pub is_admin: bool,
}

#[derive(Debug, Clone)]
pub struct NewUser {
    pub username: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub password_hash: String,
    pub is_admin: bool,
}

pub async fn create(db: &Db, new: NewUser) -> Result<User, DbError> {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO users
           (id, username, email, display_name, password_hash, is_admin, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&id)
    .bind(&new.username)
    .bind(&new.email)
    .bind(&new.display_name)
    .bind(&new.password_hash)
    .bind(new.is_admin)
    .bind(&now)
    .bind(&now)
    .execute(db.pool())
    .await?;

    Ok(User {
        id,
        username: new.username,
        email: new.email,
        display_name: new.display_name,
        password_hash: new.password_hash,
        is_admin: new.is_admin,
    })
}

pub async fn find_by_username(db: &Db, username: &str) -> Result<Option<User>, DbError> {
    let row = sqlx::query_as::<_, User>(
        "SELECT id, username, email, display_name, password_hash, is_admin
         FROM users WHERE username = ?",
    )
    .bind(username)
    .fetch_optional(db.pool())
    .await?;

    Ok(row)
}

pub async fn find_by_id(db: &Db, id: &str) -> Result<Option<User>, DbError> {
    let row = sqlx::query_as::<_, User>(
        "SELECT id, username, email, display_name, password_hash, is_admin
         FROM users WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(db.pool())
    .await?;

    Ok(row)
}

#[cfg(test)]
mod tests {
    use super::{create, find_by_id, find_by_username, NewUser};
    use crate::pool::connect_temp;

    fn new_user(username: &str) -> NewUser {
        NewUser {
            username: username.to_string(),
            email: Some(format!("{username}@example.test")),
            display_name: Some("Test User".to_string()),
            password_hash: "$argon2id$fake".to_string(),
            is_admin: true,
        }
    }

    #[tokio::test]
    async fn a_created_user_is_found_by_username() {
        let (db, _g) = connect_temp().await.unwrap();
        let created = create(&db, new_user("alice")).await.unwrap();

        let found = find_by_username(&db, "alice").await.unwrap().unwrap();

        assert_eq!(found.id, created.id);
        assert_eq!(found.username, "alice");
        assert!(found.is_admin);
    }

    #[tokio::test]
    async fn a_created_user_is_found_by_id() {
        let (db, _g) = connect_temp().await.unwrap();
        let created = create(&db, new_user("bob")).await.unwrap();

        let found = find_by_id(&db, &created.id).await.unwrap().unwrap();

        assert_eq!(found.username, "bob");
    }

    #[tokio::test]
    async fn an_unknown_username_is_none_not_an_error() {
        let (db, _g) = connect_temp().await.unwrap();

        assert!(find_by_username(&db, "nobody").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn usernames_are_unique() {
        let (db, _g) = connect_temp().await.unwrap();
        create(&db, new_user("alice")).await.unwrap();

        assert!(create(&db, new_user("alice")).await.is_err());
    }
}
