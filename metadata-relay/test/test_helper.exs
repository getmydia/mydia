# Load test support modules
Code.require_file("support/tvdb_helpers.ex", __DIR__)
Code.require_file("support/tmdb_helpers.ex", __DIR__)

# Ensure the Repo is started and run migrations for in-memory database
case MetadataRelay.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Ecto.Migrator.run(MetadataRelay.Repo, :up, all: true)

# Set sandbox mode for database transactions
Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, :manual)

ExUnit.start()
