defmodule Mydia.Repo.Migrations.FixEpisodeCascadeDeletes do
  @moduledoc """
  Change episode_id FK on media_files, downloads, and playback_progress from
  on_delete: :delete_all to on_delete: :nilify_all.

  Deleting an episode should NOT cascade-delete its media files, downloads, or
  playback progress — it should just clear the association. The old behavior
  caused "Refresh metadata" to destroy all matched media files and watch history.

  SQLite doesn't support ALTER COLUMN, so we use recreate_table for SQLite.
  """

  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @media_files_columns [
    {:id, :binary_id, [primary_key: true]},
    {:media_item_id, :binary_id,
     [references: {:media_items, [type: :binary_id, on_delete: :delete_all]}]},
    {:episode_id, :binary_id, []},
    {:path, :string, []},
    {:size, :bigint, []},
    {:quality_profile_id, :binary_id, [references: {:quality_profiles, [type: :binary_id]}]},
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

  @downloads_columns [
    {:id, :binary_id, [primary_key: true]},
    {:media_item_id, :binary_id,
     [references: {:media_items, [type: :binary_id, on_delete: :delete_all]}]},
    {:episode_id, :binary_id, []},
    {:indexer, :string, []},
    {:title, :string, [null: false]},
    {:download_url, :text, []},
    {:download_client, :string, []},
    {:download_client_id, :string, []},
    {:completed_at, :utc_datetime, []},
    {:error_message, :text, []},
    {:metadata, :text, []},
    {:import_retry_count, :integer, [default: 0]},
    {:import_last_error, :text, []},
    {:import_next_retry_at, :utc_datetime, []},
    {:import_failed_at, :utc_datetime, []},
    {:library_path_id, :binary_id,
     [references: {:library_paths, [type: :binary_id, on_delete: :nilify_all]}]},
    {:imported_at, :utc_datetime, []}
  ]

  @downloads_indexes [
    [:media_item_id],
    [:episode_id],
    [:inserted_at],
    [:download_client_id],
    {[:download_client, :download_client_id], unique: true},
    [:import_next_retry_at],
    [:import_failed_at],
    [:library_path_id],
    [:imported_at]
  ]

  @playback_columns [
    {:id, :binary_id, [primary_key: true]},
    {:user_id, :binary_id,
     [null: false, references: {:users, [type: :binary_id, on_delete: :delete_all]}]},
    {:media_item_id, :binary_id,
     [references: {:media_items, [type: :binary_id, on_delete: :delete_all]}]},
    {:episode_id, :binary_id, []},
    {:position_seconds, :integer, [null: false]},
    {:duration_seconds, :integer, [null: false]},
    {:completion_percentage, :float, [null: false]},
    {:watched, :boolean, [default: false]},
    {:last_watched_at, :utc_datetime, []}
  ]

  @playback_indexes [
    {[:user_id, :media_item_id], unique: true, where: "media_item_id IS NOT NULL"},
    {[:user_id, :episode_id], unique: true, where: "episode_id IS NOT NULL"},
    [:user_id],
    [:media_item_id],
    [:episode_id],
    [:last_watched_at]
  ]

  @doc false
  def __media_files_columns__, do: @media_files_columns

  @doc false
  def __media_files_indexes__, do: @media_files_indexes

  def up do
    fix_table_up(:media_files, @media_files_columns, @media_files_indexes, :nilify_all)
    fix_table_up(:downloads, @downloads_columns, @downloads_indexes, :nilify_all)
    fix_table_up(:playback_progress, @playback_columns, @playback_indexes, :nilify_all)
  end

  def down do
    fix_table_up(:media_files, @media_files_columns, @media_files_indexes, :delete_all)
    fix_table_up(:downloads, @downloads_columns, @downloads_indexes, :delete_all)
    fix_table_up(:playback_progress, @playback_columns, @playback_indexes, :delete_all)
  end

  defp fix_table_up(table_name, columns, indexes, episode_on_delete) do
    # Patch the episode_id column with the desired on_delete behavior
    columns =
      Enum.map(columns, fn
        {:episode_id, type, _opts} ->
          {:episode_id, type,
           [references: {:episodes, [type: :binary_id, on_delete: episode_on_delete]}]}

        other ->
          other
      end)

    if postgres?() do
      constraint = "#{table_name}_episode_id_fkey"
      pg_on_delete = if episode_on_delete == :nilify_all, do: "SET NULL", else: "CASCADE"

      execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{constraint}"

      execute """
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{constraint}
      FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE #{pg_on_delete}
      """
    else
      recreate_table(
        table: table_name,
        columns: columns,
        indexes: indexes
      )
    end
  end
end
