defmodule Mydia.Repo.Migrations.AddConnectionsRefreshedAt do
  use Ecto.Migration

  # Purely additive and nullable, so neither adapter needs a table rebuild and
  # no adapter branching is required. Existing rows read nil, which the
  # staleness check treats as "refresh on first use".
  def change do
    alter table(:media_server_configs) do
      add :connections_refreshed_at, :utc_datetime
    end
  end
end
