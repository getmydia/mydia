CREATE TABLE users (
    id            TEXT PRIMARY KEY NOT NULL,
    username      TEXT NOT NULL UNIQUE,
    email         TEXT,
    display_name  TEXT,
    password_hash TEXT NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
    inserted_at   TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE devices (
    id           TEXT PRIMARY KEY NOT NULL,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id    TEXT NOT NULL,
    device_name  TEXT NOT NULL,
    platform     TEXT NOT NULL,
    revoked_at   TEXT,
    last_seen_at TEXT NOT NULL,
    inserted_at  TEXT NOT NULL,
    UNIQUE (user_id, device_id)
);

CREATE INDEX devices_user_id_idx ON devices (user_id);

-- The database overlay layer of the configuration stack. Rows here shadow
-- environment variables, which shadow the YAML file, which shadows defaults.
CREATE TABLE settings (
    key        TEXT PRIMARY KEY NOT NULL,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
