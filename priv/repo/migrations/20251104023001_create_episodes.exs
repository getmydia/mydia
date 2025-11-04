defmodule Mydia.Repo.Migrations.CreateEpisodes do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE episodes (
        id TEXT PRIMARY KEY NOT NULL,
        media_item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
        season_number INTEGER NOT NULL,
        episode_number INTEGER NOT NULL,
        title TEXT,
        air_date TEXT,
        metadata TEXT,
        monitored INTEGER DEFAULT 1 CHECK(monitored IN (0, 1)),
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(media_item_id, season_number, episode_number)
      )
      """,
      "DROP TABLE IF EXISTS episodes"
    )

    create index(:episodes, [:media_item_id])
    create index(:episodes, [:air_date])
  end
end
