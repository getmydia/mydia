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

ExUnit.start(max_cases: max_cases, exclude: [:external, :feature, :requires_relay])
Ecto.Adapters.SQL.Sandbox.mode(Mydia.Repo, :manual)

# Refuse outbound HTTP. Nothing else stops a test reaching the production
# metadata relay: Mydia.Metadata.default_relay_config/0 falls back to
# relay.mydia.dev in test, and the cache warming that protects detail-page
# tests is opt-in and silent when forgotten (#530).
#
# Skipped when the run explicitly opts into relay-touching tests, which are
# excluded by default above. This disarms the guard for the whole run rather
# than for the tagged tests alone: a per-test allowance would have to resolve
# the current test from inside an arbitrary spawned process, and a LiveView
# async task is not a $callers descendant of its test.
relay_tags = [:external, :requires_relay]

relay_tags_included? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    tag when is_atom(tag) -> tag in relay_tags
    {tag, _value} -> tag in relay_tags
    _other -> false
  end)

unless relay_tags_included? do
  Mydia.RelayGuard.Escapes.setup()
  Req.default_options(adapter: Mydia.RelayGuard)

  ExUnit.after_suite(fn _results ->
    case Mydia.RelayGuard.Escapes.all() do
      [] ->
        :ok

      escapes ->
        IO.puts(Mydia.RelayGuard.Escapes.format(escapes))

        # ExUnit discards after_suite return values and exposes no hook to fail
        # a run, so force the exit status here.
        System.at_exit(fn _status -> exit({:shutdown, 1}) end)
    end
  end)
end

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

# The endpoint binds an OS-assigned ephemeral port (config/test.exs) so
# concurrent worktree runs cannot collide. Wallaby needs the real port, which
# is only knowable once the endpoint is listening.
{:ok, {_ip, resolved_port}} = MydiaWeb.Endpoint.server_info(:http)

if resolved_port == 0 do
  raise "test endpoint reported port 0; Wallaby would be pointed at localhost:0"
end

Application.put_env(:wallaby, :base_url, "http://localhost:#{resolved_port}")
