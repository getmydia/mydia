import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mydia, Mydia.Repo,
  database: Path.expand("../mydia_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mydia, MydiaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CuiGpJ9j+jd1Xb0aq51rBSKLxBYwqr3tvwvMyS2aXBUAlHRtSCT3/GX8fxFcV6UE",
  server: false

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
config :mydia,
  start_health_monitors: false
