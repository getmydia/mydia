defmodule Mydia.Repo.Migrations.CreatePluginWriteTables do
  @moduledoc """
  Tables behind plugin page writes: a user's standing grants per plugin and
  write surface, writes awaiting that user's confirmation, and the journal that
  makes each executed write undoable. `plugin_configs.role_ceilings` caps the
  grant scope each role may hold.

  `session_id` is "" rather than NULL for `always` grants so the unique index
  holds on both engines (NULLs are distinct in unique indexes).
  """
  use Ecto.Migration

  def change do
    alter table(:plugin_configs) do
      add :role_ceilings, :text
    end

    create table(:plugin_write_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_slug, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :surface, :text, null: false
      add :scope, :text, null: false
      add :session_id, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plugin_write_grants, [
             :plugin_slug,
             :user_id,
             :surface,
             :scope,
             :session_id
           ])

    create index(:plugin_write_grants, [:user_id])

    create table(:plugin_pending_writes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_slug, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, :text, null: false
      add :op, :text, null: false
      add :surface, :text, null: false
      add :args, :text, null: false
      add :description, :text, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:plugin_pending_writes, [:plugin_slug, :user_id, :session_id])

    create table(:plugin_write_journal, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_slug, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :op, :text, null: false
      add :surface, :text, null: false
      add :args, :text, null: false
      add :result, :text, null: false
      add :inverse, :text
      add :description, :text, null: false
      add :batch_id, :text, null: false
      add :status, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plugin_write_journal, [:plugin_slug, :user_id, :inserted_at])
    create index(:plugin_write_journal, [:batch_id])
  end
end
