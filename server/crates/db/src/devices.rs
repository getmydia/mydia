use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Device {
    pub id: String,
    pub user_id: String,
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
    pub revoked_at: Option<String>,
    pub last_seen_at: String,
    pub inserted_at: String,
}

#[derive(Debug, Clone)]
pub struct NewDevice {
    pub user_id: String,
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
}

/// Records a pairing. A device that logs in again keeps its row and its id,
/// so revoking it stays meaningful across re-logins. The name and platform
/// are refreshed, since the user may have renamed the device.
pub async fn upsert(db: &Db, new: NewDevice) -> Result<Device, DbError> {
    let now = Utc::now().to_rfc3339();
    let id = uuid::Uuid::new_v4().to_string();

    sqlx::query(
        "INSERT INTO devices
           (id, user_id, device_id, device_name, platform, last_seen_at, inserted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (user_id, device_id) DO UPDATE SET
           device_name  = excluded.device_name,
           platform     = excluded.platform,
           last_seen_at = excluded.last_seen_at",
    )
    .bind(&id)
    .bind(&new.user_id)
    .bind(&new.device_id)
    .bind(&new.device_name)
    .bind(&new.platform)
    .bind(&now)
    .bind(&now)
    .execute(db.pool())
    .await?;

    let device = sqlx::query_as::<_, Device>(
        "SELECT id, user_id, device_id, device_name, platform, revoked_at,
                last_seen_at, inserted_at
         FROM devices WHERE user_id = ? AND device_id = ?",
    )
    .bind(&new.user_id)
    .bind(&new.device_id)
    .fetch_one(db.pool())
    .await?;

    Ok(device)
}

pub async fn list_for_user(db: &Db, user_id: &str) -> Result<Vec<Device>, DbError> {
    let rows = sqlx::query_as::<_, Device>(
        "SELECT id, user_id, device_id, device_name, platform, revoked_at,
                last_seen_at, inserted_at
         FROM devices WHERE user_id = ? ORDER BY inserted_at",
    )
    .bind(user_id)
    .fetch_all(db.pool())
    .await?;

    Ok(rows)
}

pub async fn revoke(db: &Db, id: &str) -> Result<Option<Device>, DbError> {
    let now = Utc::now().to_rfc3339();

    sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ?")
        .bind(&now)
        .bind(id)
        .execute(db.pool())
        .await?;

    let device = sqlx::query_as::<_, Device>(
        "SELECT id, user_id, device_id, device_name, platform, revoked_at,
                last_seen_at, inserted_at
         FROM devices WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(db.pool())
    .await?;

    Ok(device)
}

/// Revokes a device only when it belongs to `user_id`. Returns `None` when
/// no matching row exists (unknown id or wrong owner).
pub async fn revoke_for_user(db: &Db, user_id: &str, id: &str) -> Result<Option<Device>, DbError> {
    let now = Utc::now().to_rfc3339();

    let result = sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND user_id = ?")
        .bind(&now)
        .bind(id)
        .bind(user_id)
        .execute(db.pool())
        .await?;

    if result.rows_affected() == 0 {
        return Ok(None);
    }

    let device = sqlx::query_as::<_, Device>(
        "SELECT id, user_id, device_id, device_name, platform, revoked_at,
                last_seen_at, inserted_at
         FROM devices WHERE id = ? AND user_id = ?",
    )
    .bind(id)
    .bind(user_id)
    .fetch_optional(db.pool())
    .await?;

    Ok(device)
}

#[cfg(test)]
mod tests {
    use super::{list_for_user, revoke, revoke_for_user, upsert, NewDevice};
    use crate::pool::connect_temp;
    use crate::users::{create as create_user, NewUser};
    use crate::Db;

    async fn a_user(db: &Db) -> String {
        create_user(
            db,
            NewUser {
                username: "alice".to_string(),
                email: None,
                display_name: None,
                password_hash: "$argon2id$fake".to_string(),
                is_admin: true,
            },
        )
        .await
        .unwrap()
        .id
    }

    fn new_device(user_id: &str) -> NewDevice {
        NewDevice {
            user_id: user_id.to_string(),
            device_id: "hardware-abc".to_string(),
            device_name: "Living Room TV".to_string(),
            platform: "android".to_string(),
        }
    }

    #[tokio::test]
    async fn a_device_is_listed_for_its_user() {
        let (db, _g) = connect_temp().await.unwrap();
        let user_id = a_user(&db).await;

        upsert(&db, new_device(&user_id)).await.unwrap();
        let devices = list_for_user(&db, &user_id).await.unwrap();

        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].device_name, "Living Room TV");
    }

    #[tokio::test]
    async fn pairing_the_same_hardware_twice_does_not_duplicate() {
        let (db, _g) = connect_temp().await.unwrap();
        let user_id = a_user(&db).await;

        upsert(&db, new_device(&user_id)).await.unwrap();

        let mut renamed = new_device(&user_id);
        renamed.device_name = "Bedroom TV".to_string();
        upsert(&db, renamed).await.unwrap();

        let devices = list_for_user(&db, &user_id).await.unwrap();

        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].device_name, "Bedroom TV");
    }

    #[tokio::test]
    async fn revoking_sets_revoked_at() {
        let (db, _g) = connect_temp().await.unwrap();
        let user_id = a_user(&db).await;
        let device = upsert(&db, new_device(&user_id)).await.unwrap();

        let revoked = revoke(&db, &device.id).await.unwrap().unwrap();

        assert!(revoked.revoked_at.is_some());
    }

    #[tokio::test]
    async fn revoking_an_unknown_device_is_none() {
        let (db, _g) = connect_temp().await.unwrap();

        assert!(revoke(&db, "no-such-device").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn revoke_for_user_refuses_another_users_device() {
        let (db, _g) = connect_temp().await.unwrap();
        let owner = a_user(&db).await;
        let other = create_user(
            &db,
            NewUser {
                username: "bob".to_string(),
                email: None,
                display_name: None,
                password_hash: "$argon2id$fake".to_string(),
                is_admin: false,
            },
        )
        .await
        .unwrap()
        .id;
        let device = upsert(&db, new_device(&owner)).await.unwrap();

        assert!(revoke_for_user(&db, &other, &device.id)
            .await
            .unwrap()
            .is_none());
        assert!(revoke_for_user(&db, &owner, &device.id)
            .await
            .unwrap()
            .unwrap()
            .revoked_at
            .is_some());
    }
}
