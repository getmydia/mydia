defmodule Mydia.Repo.Migrations.CreatePluginShelves do
  @moduledoc """
  Tables behind plugin shelves: one row per plugin shelf per user, the verified
  items it currently holds, and the titles a user dismissed from it.

  Dismissals are their own table, keyed on the shelf's slug and key rather than
  its row, so they outlive both the fill that produced the item and the shelf
  row itself.
  """
  use Ecto.Migration

  def change do
    create table(:plugin_shelves, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_slug, :text, null: false
      add :shelf_key, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "idle"
      add :filled_at, :utc_datetime_usec
      add :stale_at, :utc_datetime_usec
      add :failure_count, :integer, null: false, default: 0
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_shelves, [:plugin_slug, :shelf_key, :user_id])
    create index(:plugin_shelves, [:user_id])

    create table(:plugin_shelf_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :shelf_id, references(:plugin_shelves, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :media_type, :text, null: false
      add :provider, :text, null: false
      add :provider_id, :integer, null: false
      add :reason, :text
      add :title, :text, null: false
      add :year, :integer
      add :poster_path, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plugin_shelf_items, [:shelf_id, :position])

    create table(:plugin_shelf_dismissals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_slug, :text, null: false
      add :shelf_key, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :media_type, :text, null: false
      add :provider, :text, null: false
      add :provider_id, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :plugin_shelf_dismissals,
             [:plugin_slug, :shelf_key, :user_id, :media_type, :provider, :provider_id],
             name: :plugin_shelf_dismissals_unique
           )
  end
end
