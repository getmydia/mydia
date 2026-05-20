defmodule Mydia.Repo.Migrations.FixTorrentStreamingSessions do
  use Ecto.Migration

  def up do
    # Make media_item_id nullable — sessions can be episode-only
    alter table(:torrent_streaming_sessions) do
      modify :media_item_id,
             references(:media_items, type: :binary_id, on_delete: :delete_all),
             null: true

      # Add episode_id column referenced in schema/resolver but missing from original migration
      add :episode_id, references(:episodes, type: :binary_id, on_delete: :delete_all), null: true

      # Make infohash nullable — it isn't known until magnet metadata is fetched;
      # inserting a session record before metadata arrives would fail with null: false
      modify :infohash, :string, null: true
    end

    create index(:torrent_streaming_sessions, [:episode_id])
  end

  def down do
    drop index(:torrent_streaming_sessions, [:episode_id])

    alter table(:torrent_streaming_sessions) do
      modify :media_item_id,
             references(:media_items, type: :binary_id, on_delete: :delete_all),
             null: false

      remove :episode_id

      modify :infohash, :string, null: false
    end
  end
end
