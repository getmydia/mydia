defmodule Mydia.Repo.Migrations.ScopeSubtitleHashUniquenessToMediaFile do
  use Ecto.Migration

  # The original index made subtitle_hash globally unique, which is wrong: two
  # rips of the same movie legitimately share a subtitle, and the hash is a
  # property of the subtitle rather than of the pairing. Under the global index
  # the second media file could never store its own row, so the application
  # handed back the first file's subtitle, which the delivery layer then refused
  # as belonging to another media file.
  #
  # Only indexes change here, so SQLite and PostgreSQL take the same path with
  # no table rebuild.
  def up do
    drop_if_exists index(:subtitles, [:subtitle_hash])
    create unique_index(:subtitles, [:media_file_id, :subtitle_hash])
  end

  def down do
    drop_if_exists index(:subtitles, [:media_file_id, :subtitle_hash])
    create unique_index(:subtitles, [:subtitle_hash])
  end
end
