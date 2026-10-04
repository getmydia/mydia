defmodule Mydia.Repo.Migrations.CreatePluginSources do
  use Ecto.Migration

  @moduledoc """
  Third-party plugin catalogs and the pin from an installed plugin to the
  catalog it came from. A source row stores the minisign key trusted when it was
  added. `plugin_source_id` is nulled when its source is removed, and the
  plugin then reads as "source removed" (`Mydia.Plugins.Sources.origin/1`).
  """

  def change do
    create table(:plugin_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :text, null: false
      add :name, :text
      add :public_key, :text, null: false
      add :key_id, :text, null: false
      add :declared, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :last_error, :text
      add :last_fetched_at, :utc_datetime_usec
      add :plugin_count, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_sources, [:url])

    alter table(:plugin_configs) do
      add :plugin_source_id,
          references(:plugin_sources, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:plugin_configs, [:plugin_source_id])
  end
end
