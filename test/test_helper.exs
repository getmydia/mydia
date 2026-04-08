# SQLite doesn't handle high concurrency well, even with WAL mode.
# Use 1 concurrent case for SQLite to avoid "Database busy" errors.
# PostgreSQL handles concurrency fine, so use all available schedulers.
# Exclude external integration tests by default (require external services)
# Exclude feature tests by default (require chromedriver)
# Exclude relay tests by default (require connected relay service)
# Run specific tests explicitly with: mix test --include <tag>
max_cases =
  if System.get_env("DATABASE_TYPE") == "postgres" do
    System.schedulers_online()
  else
    1
  end

ExUnit.start(max_cases: max_cases, exclude: [:external, :feature, :requires_relay, :e2e])
Ecto.Adapters.SQL.Sandbox.mode(Mydia.Repo, :manual)

# Clear runtime config indexers, download clients, and media servers so tests
# never accidentally hit real external services (e.g. Prowlarr from Docker env vars).
# Tests that need indexers should create their own via Bypass + Settings.create_indexer_config.
case Application.get_env(:mydia, :runtime_config) do
  %{} = config ->
    Application.put_env(
      :mydia,
      :runtime_config,
      %{config | indexers: [], download_clients: [], media_servers: []}
    )

  _ ->
    :ok
end

# Configure ExMachina
{:ok, _} = Application.ensure_all_started(:ex_machina)

# Start Wallaby for feature tests only if chromedriver is available
# Check if we can find chromedriver in PATH
chromedriver_available =
  case System.find_executable("chromedriver") do
    nil ->
      # Also check custom path from config
      case Application.get_env(:wallaby, :chromedriver)[:path] do
        nil -> false
        path -> File.exists?(path)
      end

    _path ->
      true
  end

if chromedriver_available do
  {:ok, _} = Application.ensure_all_started(:wallaby)
else
  IO.puts("""
  \n⚠️  chromedriver not found - Wallaby feature tests will be skipped.
  To run feature tests, install chromedriver:
    - macOS: brew install chromedriver
    - Ubuntu: apt-get install chromium-chromedriver
    - Or set config :wallaby, :chromedriver, path: "/path/to/chromedriver"
  """)
end
