import Config

# Configure your database based on DATABASE_TYPE environment variable
# Default to PostgreSQL for faster parallel test execution locally
# CI runs tests on both PostgreSQL and SQLite
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database_type =
  case System.get_env("DATABASE_TYPE") do
    "sqlite" -> :sqlite
    "postgres" -> :postgres
    "postgresql" -> :postgres
    # Default to PostgreSQL locally for faster parallel execution
    _ -> :postgres
  end

# Set database_type for runtime helpers (used by Mydia.DB and migrations)
config :mydia, :database_type, database_type

case database_type do
  :postgres ->
    config :mydia, Mydia.Repo,
      hostname: System.get_env("DATABASE_HOST") || "localhost",
      port: String.to_integer(System.get_env("DATABASE_PORT") || "5433"),
      database:
        System.get_env("DATABASE_NAME") || "mydia_test#{System.get_env("MIX_TEST_PARTITION")}",
      username: System.get_env("DATABASE_USER") || "postgres",
      password: System.get_env("DATABASE_PASSWORD") || "postgres",
      pool_size: 5,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_timeout: 60_000,
      timeout: 60_000

  :sqlite ->
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
      busy_timeout: 30_000
end

# We run a server during test for Wallaby browser-based feature tests.
# The server is enabled by default. Individual tests that don't need it
# won't be affected since they use Phoenix.ConnTest directly.
config :mydia, MydiaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CuiGpJ9j+jd1Xb0aq51rBSKLxBYwqr3tvwvMyS2aXBUAlHRtSCT3/GX8fxFcV6UE",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Disable crash reporter logger backend in test to avoid SQL Sandbox issues
config :logger, backends: [:console]

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
  sql_sandbox: true

# Wallaby configuration for browser-based feature tests
# Uses Chrome/Chromium in headless mode
# Chromedriver path is auto-detected, or can be set via CHROMEDRIVER_PATH
wallaby_headless = System.get_env("WALLABY_HEADLESS", "true") == "true"

wallaby_chromedriver_opts =
  case System.get_env("CHROMEDRIVER_PATH") do
    nil -> [headless: wallaby_headless]
    path -> [path: path, headless: wallaby_headless]
  end

config :wallaby,
  driver: Wallaby.Chrome,
  base_url: "http://localhost:4002",
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots",
  chromedriver: wallaby_chromedriver_opts

# Faster HTTP timeouts in test mode to avoid long waits for unreachable hosts
# This significantly speeds up tests that hit non-existent endpoints
config :mydia, :test_http_options,
  connect_timeout: 1_000,
  receive_timeout: 2_000
