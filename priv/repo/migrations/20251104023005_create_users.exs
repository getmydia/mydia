defmodule Mydia.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE users (
        id TEXT PRIMARY KEY NOT NULL,
        username TEXT UNIQUE,
        email TEXT UNIQUE,
        password_hash TEXT,
        oidc_sub TEXT UNIQUE,
        oidc_issuer TEXT,
        role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('admin', 'user', 'readonly')),
        display_name TEXT,
        avatar_url TEXT,
        last_login_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS users"
    )

    create index(:users, [:oidc_sub, :oidc_issuer])
  end
end
