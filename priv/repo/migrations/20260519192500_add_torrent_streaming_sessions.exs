defmodule Mydia.Repo.Migrations.AddTorrentStreamingSessions do
  use Ecto.Migration

  def change do
    create table(:torrent_streaming_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :release_title, :string, null: false
      add :infohash, :string, null: false
      add :magnet, :text, null: false
      add :file_id, :integer
      add :staging_path, :string
      add :total_bytes, :bigint
      add :state, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :last_progress_at, :utc_datetime
      add :download_progress, :float, default: 0.0

      timestamps(type: :utc_datetime)
    end

    create index(:torrent_streaming_sessions, [:state])
    create index(:torrent_streaming_sessions, [:media_item_id])
    create index(:torrent_streaming_sessions, [:user_id])

    create unique_index(:torrent_streaming_sessions, [:infohash],
             where: "state NOT IN ('completed', 'failed', 'cancelled')"
           )
  end
end
