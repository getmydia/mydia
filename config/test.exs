import Config

# Configure your database based on DATABASE_TYPE environment variable
# Use DATABASE_TYPE=postgres to use PostgreSQL, otherwise SQLite is used
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database_adapter =
  case System.get_env("DATABASE_TYPE") do
    "postgres" -> Ecto.Adapters.Postgres
    "postgresql" -> Ecto.Adapters.Postgres
    _ -> Ecto.Adapters.SQLite3
  end

# Set database_adapter for runtime helpers (used by Mydia.DB and migrations)
config :mydia, :database_adapter, database_adapter

case database_adapter do
  Ecto.Adapters.Postgres ->
    config :mydia, Mydia.Repo,
      hostname: System.get_env("DATABASE_HOST") || "localhost",
      port: String.to_integer(System.get_env("DATABASE_PORT") || "5433"),
      database:
        System.get_env("DATABASE_NAME") || "mydia_test#{System.get_env("MIX_TEST_PARTITION")}",
      username: System.get_env("DATABASE_USER") || "postgres",
      password: System.get_env("DATABASE_PASSWORD") || "postgres",
      pool_size: 10,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_timeout: 60_000,
      timeout: 60_000

  Ecto.Adapters.SQLite3 ->
    config :mydia, Mydia.Repo,
      database: Path.expand("../mydia_test.db", __DIR__),
      pool_size: 5,
      pool: Ecto.Adapters.SQL.Sandbox,
      # SQLite-specific settings for better test concurrency
      journal_mode: :wal,
      cache_size: -64000,
      temp_store: :memory,
      pool_timeout: 60_000,
      timeout: 60_000,
      # Increase busy timeout to handle concurrent writes
      busy_timeout: 30_000,
      # See config/dev.exs. The SQL sandbox begins with mode: :transaction,
      # which exqlite maps to a plain BEGIN, so this does not change how the
      # sandbox wraps tests.
      default_transaction_mode: :immediate
end

# We run a server during test for Wallaby browser-based feature tests.
# The server is enabled by default. Individual tests that don't need it
# won't be affected since they use Phoenix.ConnTest directly.
config :mydia, MydiaWeb.Endpoint,
  # port: 0 asks the OS for a free ephemeral port, so concurrent test runs in
  # different worktrees can never collide. test_helper.exs resolves the real
  # port once the endpoint is listening and hands it to Wallaby.
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: "CuiGpJ9j+jd1Xb0aq51rBSKLxBYwqr3tvwvMyS2aXBUAlHRtSCT3/GX8fxFcV6UE",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable Oban during testing to prevent pool conflicts with SQL Sandbox
# Using engine: false disables Oban's engine entirely in test mode
config :mydia, Oban,
  testing: :manual,
  engine: false,
  queues: false,
  plugins: false

# Disable health monitoring processes in test mode
# Enable SQL sandbox for Wallaby browser tests
config :mydia,
  start_health_monitors: false,
  database_auto_repair: false,
  sql_sandbox: true,
  # Use a long refresh interval for LiveView admin page to prevent
  # timer-triggered re-renders from clearing flash messages during tests
  admin_refresh_interval: :timer.minutes(10)

# Disable search delay in tests (production uses 3000ms to throttle API calls)
config :mydia, :episode_monitor, search_delay_ms: 0

# Guardian JWT configuration for tests
config :mydia, Mydia.Auth.Guardian,
  issuer: "mydia",
  secret_key: "test-secret-key-for-jwt-signing",
  ttl: {30, :days},
  allowed_drift: 0

config :mydia, Mydia.RemoteAccess.MediaToken,
  issuer: "mydia",
  secret_key: "test-secret-key-for-jwt-signing",
  ttl: {24, :hours},
  allowed_drift: 0

# P2P keypair path for tests - use a temp directory
config :mydia, :p2p_keypair_path, "/tmp/mydia_test_p2p_keypair.bin"

# Remote access stays off in tests. With it on, Mydia.P2p.Server starts for every
# test run, which loads the Rustler NIF, opens an iroh endpoint and dials
# cae1-1.relay.mydia.dev. Tests that need the flag on set it through
# Mydia.RemoteAccessHelpers.set_remote_access/1 instead.
config :mydia, :features, remote_access_enabled: false

# Keep Tower from shipping crash reports during the test suite: register no
# real reporter (the in-memory ephemeral reporter is a no-op for our purposes)
# and suppress plain-Logger-message capture.
config :tower,
  reporters: [Tower.EphemeralReporter],
  log_level: :none

# Wallaby configuration for browser-based feature tests
# Uses Chrome/Chromium in headless mode
# Chromedriver path is auto-detected, or can be set via CHROMEDRIVER_PATH
wallaby_headless = System.get_env("WALLABY_HEADLESS", "true") == "true"
is_ci = System.get_env("CI") == "true" || System.get_env("GITHUB_ACTIONS") == "true"

# `binary` pins the *browser* the way `path` pins the driver, and it matters as
# much. Wallaby resolves Chrome itself in `Wallaby.Chrome.find_chrome_executable/0`,
# which searches `[chromedriver_config[:binary] | default_paths]` and falls
# through to whatever `google-chrome` is on PATH. On a GitHub runner that is the
# system Chrome, which tracks stable and moves independently of nixpkgs, so
# Wallaby compared it against devenv's pinned chromedriver and aborted every
# session with "invalid session id" once the runner image reached Chrome 151
# while nixpkgs pinned chromedriver 149.
#
# `scripts/run-feature-tests.sh` already prefers CHROME_PATH for exactly this
# reason (see `get_chrome_version`), so its preflight reported a clean 149/149
# match and Wallaby then failed its own independent check. Setting `binary` here
# is what makes the two agree.
wallaby_chromedriver_opts =
  [headless: wallaby_headless]
  |> then(fn opts ->
    case System.get_env("CHROMEDRIVER_PATH") do
      nil -> opts
      path -> Keyword.put(opts, :path, path)
    end
  end)
  |> then(fn opts ->
    case System.get_env("CHROME_PATH") do
      nil -> opts
      binary -> Keyword.put(opts, :binary, binary)
    end
  end)

# Chrome capabilities for headless mode
# These are especially important for CI environments
chrome_capabilities =
  if is_ci do
    %{
      chromeOptions: %{
        args: [
          "--headless=new",
          "--no-sandbox",
          "--disable-gpu",
          "--disable-dev-shm-usage",
          "--window-size=1920,1080",
          "--disable-software-rasterizer",
          "--disable-extensions",
          "--remote-debugging-port=9222"
        ]
      }
    }
  else
    %{}
  end

config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots",
  chromedriver: wallaby_chromedriver_opts,
  capabilities: chrome_capabilities,
  # Increase timeout for CI environments which may be slower
  max_wait_time: 10_000

# The sampler is a singleton reading a process registry that is global to the
# whole suite, so a ticking sampler picks up sessions any other test happens to
# leave running and leaks them into unrelated assertions. It also runs periodic
# queries for the entire test run for no benefit. Tests that need samples drive
# ticks explicitly with `GenServer.call(pid, :tick_now)` on their own instance.
config :mydia, Mydia.Streaming.SessionSampler, tick: false

# Migration tests start this repo themselves, one temp database per test, so it
# is intentionally absent from :ecto_repos and carries no :database here.
config :mydia, Mydia.MigrationTestRepo,
  pool_size: 1,
  foreign_keys: :on,
  priv: "priv/repo"
