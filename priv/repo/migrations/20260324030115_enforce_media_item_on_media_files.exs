defmodule Mydia.Repo.Migrations.EnforceMediaItemOnMediaFiles do
  @moduledoc """
  Make media_item_id NOT NULL on media_files.

  Every MediaFile must belong to a MediaItem. Previously, media_item_id and
  episode_id were mutually exclusive optional FKs. Now media_item_id is required
  and episode_id is an optional refinement (both can be set for TV show files).

  Steps:
  1. Backfill media_item_id from episode.media_item_id (for files with only episode_id)
  2. Delete true orphans (both parents NULL — overwhelmingly trashed files)
  3. Recreate table with NOT NULL on media_item_id

  This migration is idempotent — safe to run multiple times.
  """

  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  # Full column definitions for recreate_table
  # Note: media_item_id is now NOT NULL, episode_id allows coexistence (no mutual exclusivity)
  @media_files_columns [
    {:id, :binary_id, [primary_key: true]},
    {:media_item_id, :binary_id,
     [null: false, references: {:media_items, [type: :binary_id, on_delete: :delete_all]}]},
    {:episode_id, :binary_id,
     [references: {:episodes, [type: :binary_id, on_delete: :nilify_all]}]},
    {:path, :string, []},
    {:size, :bigint, []},
    {:quality_profile_id, :binary_id,
     [references: {:quality_profiles, [type: :binary_id, on_delete: :nilify_all]}]},
    {:resolution, :string, []},
    {:codec, :string, []},
    {:hdr_format, :string, []},
    {:audio_codec, :string, []},
    {:bitrate, :integer, []},
    {:verified_at, :utc_datetime, []},
    {:metadata, :text, []},
    {:relative_path, :string, []},
    {:library_path_id, :binary_id,
     [references: {:library_paths, [type: :binary_id, on_delete: :delete_all]}]},
    {:cover_blob, :string, []},
    {:sprite_blob, :string, []},
    {:vtt_blob, :string, []},
    {:preview_blob, :string, []},
    {:phash, :string, []},
    {:generated_at, :utc_datetime, []},
    {:trashed_at, :utc_datetime, []}
  ]

  @media_files_indexes [
    [:media_item_id],
    [:episode_id],
    [:library_path_id],
    [:phash],
    [:trashed_at]
  ]

  def up do
    # Step 1: Backfill media_item_id from episode.media_item_id
    # Idempotent: only updates rows where media_item_id IS NULL
    execute("""
    UPDATE media_files
    SET media_item_id = (
      SELECT episodes.media_item_id
      FROM episodes
      WHERE episodes.id = media_files.episode_id
    )
    WHERE media_files.media_item_id IS NULL
      AND media_files.episode_id IS NOT NULL
    """)

    # Step 2: Delete true orphans (both parents NULL)
    # These are files with no association — overwhelmingly trashed
    execute("""
    DELETE FROM media_files
    WHERE media_item_id IS NULL AND episode_id IS NULL
    """)

    # Step 3: Safety check — abort if any NULLs remain
    %{rows: [[count]]} =
      repo().query!("SELECT COUNT(*) FROM media_files WHERE media_item_id IS NULL")

    if count > 0 do
      raise """
      Cannot apply NOT NULL constraint: #{count} media_files still have NULL media_item_id.
      These files have episode_id set but the episode's media_item_id is also NULL.
      Please investigate and fix these records before running this migration.
      """
    end

    # Step 4: Recreate table with NOT NULL on media_item_id
    recreate_table(
      table: :media_files,
      columns: @media_files_columns,
      indexes: @media_files_indexes
    )
  end

  def down do
    # Reverse: make media_item_id nullable again
    nullable_columns =
      Enum.map(@media_files_columns, fn
        {:media_item_id, type, opts} ->
          {:media_item_id, type, Keyword.delete(opts, :null)}

        other ->
          other
      end)

    recreate_table(
      table: :media_files,
      columns: nullable_columns,
      indexes: @media_files_indexes
    )
  end
end
