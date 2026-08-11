defmodule Mydia.Repo.Migrations.CreateSyncRuns do
  use Ecto.Migration

  def change do
    create table(:sync_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Provider-agnostic from the start: "plex", "jellyfin", "trakt", or a
      # plugin slug. Not a FK, because instances live in three different tables.
      add :provider, :string, null: false
      add :provider_instance_id, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :direction, :string
      add :status, :string, null: false
      add :skip_reason, :string
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :counts, :text
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sync_runs, [:provider, :provider_instance_id, :inserted_at])
    create index(:sync_runs, [:inserted_at])
  end
end
