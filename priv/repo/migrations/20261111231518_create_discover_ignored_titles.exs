defmodule Mydia.Repo.Migrations.CreateDiscoverIgnoredTitles do
  use Ecto.Migration

  # Per-user Discover ignore list (#1379). media_type is part of the key because
  # TMDB numbers movies and TV separately: one id can name one of each.
  def change do
    create table(:discover_ignored_titles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :media_type, :text, null: false
      add :provider, :text, null: false
      add :provider_id, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:discover_ignored_titles, [
             :user_id,
             :media_type,
             :provider,
             :provider_id
           ])
  end
end
