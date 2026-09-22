defmodule MetadataRelay.Repo.Migrations.CreatePlayerLogs do
  use Ecto.Migration

  def change do
    create table(:player_log_devices, primary_key: false) do
      add :device_id, :text, primary_key: true
      add :name, :text
      add :platform, :text
      add :os_version, :text
      add :app_version, :text
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :bytes_today, :integer, null: false, default: 0
      add :bytes_day, :date
    end

    create table(:player_log_chunks) do
      add :device_id, :text, null: false
      add :kind, :text, null: false
      add :path, :text, null: false
      add :first_t, :bigint, null: false
      add :last_t, :bigint, null: false
      add :line_count, :integer, null: false
      add :bytes, :integer, null: false
      add :sessions, :text, null: false
      add :report_code, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:player_log_chunks, [:device_id, :last_t])
    create index(:player_log_chunks, [:report_code])
    create index(:player_log_chunks, [:kind, :inserted_at])

    create table(:player_log_reports, primary_key: false) do
      add :code, :text, primary_key: true
      add :device_id, :text, null: false
      add :note, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
