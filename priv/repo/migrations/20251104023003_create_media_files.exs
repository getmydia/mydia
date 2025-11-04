defmodule Mydia.Repo.Migrations.CreateMediaFiles do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE media_files (
        id TEXT PRIMARY KEY NOT NULL,
        media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
        episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,
        path TEXT NOT NULL UNIQUE,
        size INTEGER,
        quality_profile_id TEXT REFERENCES quality_profiles(id),
        resolution TEXT,
        codec TEXT,
        hdr_format TEXT,
        audio_codec TEXT,
        bitrate INTEGER,
        verified_at TEXT,
        metadata TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CHECK(
          (media_item_id IS NOT NULL AND episode_id IS NULL) OR
          (media_item_id IS NULL AND episode_id IS NOT NULL)
        )
      )
      """,
      "DROP TABLE IF EXISTS media_files"
    )

    create index(:media_files, [:media_item_id])
    create index(:media_files, [:episode_id])
  end
end
