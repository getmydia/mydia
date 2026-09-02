defmodule Mydia.Repo.Migrations.CreateMediaFileEpisodes do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Lets one media file cover more than one episode.

  A release such as `S01E09E10` holds two episodes in a single file, but
  `media_files.episode_id` is a single FK, so only the first episode could ever
  claim it. Every trailing episode of a multi-episode file therefore looked
  un-downloaded even though its content was already on disk.

  `media_files.episode_id` stays as the primary (first) episode so existing
  queries keep working unchanged. This join table records the full set.
  """

  def up do
    create table(:media_file_episodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id,
          references(:media_files, type: :binary_id, on_delete: :delete_all),
          null: false

      add :episode_id,
          references(:episodes, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_file_episodes, [:media_file_id, :episode_id])
    create index(:media_file_episodes, [:episode_id])

    # Backfill the existing one-file-one-episode links so the new association
    # returns exactly what the old `has_many` returned. Plain SQL on purpose:
    # portable across SQLite and PostgreSQL, and independent of app code.
    execute("""
    INSERT INTO media_file_episodes (id, media_file_id, episode_id, inserted_at, updated_at)
    SELECT
      #{uuid_expr()},
      mf.id,
      mf.episode_id,
      #{now_expr()},
      #{now_expr()}
    FROM media_files mf
    WHERE mf.episode_id IS NOT NULL
    """)
  end

  def down do
    drop table(:media_file_episodes)
  end

  # SQLite has no gen_random_uuid(). Build a dashed, v4-shaped string, because
  # the ids Ecto reads back are dashed UUIDs; a bare hex blob would not load.
  defp uuid_expr do
    if postgres?() do
      "gen_random_uuid()"
    else
      """
      lower(
        hex(randomblob(4)) || '-' ||
        hex(randomblob(2)) || '-4' ||
        substr(hex(randomblob(2)), 2) || '-' ||
        substr('89ab', abs(random()) % 4 + 1, 1) ||
        substr(hex(randomblob(2)), 2) || '-' ||
        hex(randomblob(6))
      )
      """
    end
  end

  defp now_expr do
    if postgres?() do
      "NOW()"
    else
      "STRFTIME('%Y-%m-%dT%H:%M:%SZ', 'now')"
    end
  end
end
