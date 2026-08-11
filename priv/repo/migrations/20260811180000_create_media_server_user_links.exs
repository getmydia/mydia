defmodule Mydia.Repo.Migrations.CreateMediaServerUserLinks do
  use Ecto.Migration

  def change do
    create table(:media_server_user_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_server_config_id,
          references(:media_server_configs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :plex_account_id, :string
      add :plex_username, :string
      add :access_token, :string
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    # One link per (server, Mydia user). Without this, a user could be mapped
    # twice and sync would run against both accounts.
    create unique_index(:media_server_user_links, [:media_server_config_id, :user_id])
    create index(:media_server_user_links, [:user_id])
  end
end
