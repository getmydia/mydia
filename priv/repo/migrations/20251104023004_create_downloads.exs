defmodule Mydia.Repo.Migrations.CreateDownloads do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE downloads (
        id TEXT PRIMARY KEY NOT NULL,
        media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
        episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,
        status TEXT NOT NULL CHECK(status IN ('pending', 'downloading', 'completed', 'failed', 'cancelled')),
        indexer TEXT,
        title TEXT NOT NULL,
        download_url TEXT,
        download_client TEXT,
        download_client_id TEXT,
        progress REAL CHECK(progress IS NULL OR (progress >= 0 AND progress <= 100)),
        estimated_completion TEXT,
        completed_at TEXT,
        error_message TEXT,
        metadata TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS downloads"
    )

    create index(:downloads, [:status])
    create index(:downloads, [:media_item_id])
    create index(:downloads, [:episode_id])
    create index(:downloads, [:inserted_at])
  end
end
