defmodule Mydia.Repo.Migrations.AddPlexConnectionResilience do
  use Ecto.Migration

  # Purely additive: new nullable columns need no adapter branching, since
  # neither SQLite nor PostgreSQL requires a table rebuild to add one.
  def change do
    alter table(:media_server_configs) do
      # The stable Plex server identity. Every advertised address can change;
      # this cannot, so it is what rediscovery matches on.
      add :machine_identifier, :string
      # Every advertised connection, stored as JSON text so both adapters agree.
      add :connections, :text
      add :server_access_token, :string
      add :last_auth_error, :string
      add :last_auth_error_at, :utc_datetime
    end

    create index(:media_server_configs, [:machine_identifier])
  end
end
