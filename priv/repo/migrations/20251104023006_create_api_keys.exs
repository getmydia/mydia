defmodule Mydia.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE api_keys (
        id TEXT PRIMARY KEY NOT NULL,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        key_hash TEXT NOT NULL UNIQUE,
        last_used_at TEXT,
        expires_at TEXT,
        inserted_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS api_keys"
    )

    create index(:api_keys, [:user_id])
  end
end
