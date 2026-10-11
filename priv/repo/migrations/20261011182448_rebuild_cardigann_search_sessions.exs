defmodule Mydia.Repo.Migrations.RebuildCardigannSearchSessions do
  use Ecto.Migration

  # Sessions are disposable: dropping them costs each tracker one re-login.
  # No table references cardigann_search_sessions, so a drop and create is safe
  # on both adapters and avoids a SQLite table rebuild for the nullability change.
  def up do
    drop table(:cardigann_search_sessions)

    create table(:cardigann_search_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cardigann_definition_id,
          references(:cardigann_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :cookies, :text, null: false
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cardigann_search_sessions, [:cardigann_definition_id])
  end

  def down do
    drop table(:cardigann_search_sessions)

    create table(:cardigann_search_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cardigann_definition_id,
          references(:cardigann_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :cookies, :text, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cardigann_search_sessions, [:cardigann_definition_id])
    create index(:cardigann_search_sessions, [:expires_at])
  end
end
