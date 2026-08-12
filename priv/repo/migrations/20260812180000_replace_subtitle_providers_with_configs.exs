defmodule Mydia.Repo.Migrations.ReplaceSubtitleProvidersWithConfigs do
  use Ecto.Migration

  # subtitle_providers is dropped rather than migrated. It is read by nothing and
  # written by nothing, so no install can be holding rows in it. A drop and
  # create is identical on SQLite and PostgreSQL, so this needs no adapter
  # branching.
  def up do
    drop_if_exists table(:subtitle_providers)

    create table(:subtitle_provider_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :priority, :integer, default: 0, null: false
      add :username, :string
      add :password, :string
      add :api_key, :string
      add :env_name, :string
      add :connection_settings, :text
      add :quota_remaining, :integer
      add :quota_total, :integer
      add :quota_reset_at, :utc_datetime
      add :vip_status, :boolean, default: false, null: false
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitle_provider_configs, [:name])
    create index(:subtitle_provider_configs, [:enabled, :priority])
  end

  def down do
    drop table(:subtitle_provider_configs)
  end
end
