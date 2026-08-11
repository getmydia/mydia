defmodule Mydia.Repo.Migrations.CreateWatchSyncTables do
  use Ecto.Migration

  def change do
    # User-independent: a remote id belongs to the server, not to a viewer.
    # Keeping it separate stops N users storing N copies of the same rating key,
    # and it is what removes the full-library crawl on every export.
    create table(:remote_item_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :provider_instance_id, :string, null: false
      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all)
      add :episode_id, references(:episodes, type: :binary_id, on_delete: :delete_all)
      add :remote_id, :string, null: false
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:remote_item_mappings, [:provider, :provider_instance_id, :media_item_id],
             name: :remote_item_mappings_movie_index
           )

    create unique_index(:remote_item_mappings, [:provider, :provider_instance_id, :episode_id],
             name: :remote_item_mappings_episode_index
           )

    create index(:remote_item_mappings, [:provider, :provider_instance_id, :remote_id])

    # Per-user: the last state both sides agreed on. This is the only record
    # that an item was ever watched, because a local unwatch deletes the
    # playback_progress row outright and emits no event.
    create table(:watch_sync_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_instance_id, :string, null: false
      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all)
      add :episode_id, references(:episodes, type: :binary_id, on_delete: :delete_all)
      add :synced_watched, :boolean, default: false, null: false
      add :synced_position_seconds, :integer
      add :synced_at, :utc_datetime
      add :remote_last_watched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :watch_sync_states,
             [:user_id, :provider, :provider_instance_id, :media_item_id],
             name: :watch_sync_states_movie_index
           )

    create unique_index(
             :watch_sync_states,
             [:user_id, :provider, :provider_instance_id, :episode_id],
             name: :watch_sync_states_episode_index
           )
  end
end
