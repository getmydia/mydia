defmodule Mydia.Repo.Migrations.CreateMediaItems do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE media_items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('movie', 'tv_show')),
        title TEXT NOT NULL,
        original_title TEXT,
        year INTEGER,
        tmdb_id INTEGER UNIQUE,
        imdb_id TEXT,
        metadata TEXT,
        monitored INTEGER DEFAULT 1 CHECK(monitored IN (0, 1)),
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS media_items"
    )

    create index(:media_items, [:imdb_id])
    create index(:media_items, [:title])
    create index(:media_items, [:type])
  end
end
