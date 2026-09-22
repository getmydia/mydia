import Config

# Test configuration
config :logger, level: :warning

# Disable Phoenix endpoint server in tests
config :metadata_relay, MetadataRelayWeb.Endpoint,
  http: [port: 4002],
  server: false

# Use file-based SQLite database for tests
# In-memory databases don't persist across connections, breaking mix ecto.migrate
config :metadata_relay, MetadataRelay.Repo,
  database: Path.expand("../metadata_relay_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :metadata_relay,
  rendezvous_master_pepper: "test-pepper-not-for-production"

config :metadata_relay, MetadataRelay.Feedback.Notifier,
  recipient: "maintainer@example.com",
  from: "metadata-relay@example.com",
  dashboard_url: "https://relay.example.com"

config :metadata_relay, MetadataRelay.Mailer, adapter: Swoosh.Adapters.Test

# Tests point `dir` at a tmp directory of their own (PlayerLogsHelpers) and
# call PlayerLogs.sweep/1 directly, so the hourly sweeper never runs.
config :metadata_relay, :player_logs,
  dir: Path.join(System.tmp_dir!(), "metadata_relay_player_logs_test"),
  max_bytes: 2_147_483_648,
  report_budget_bytes: 268_435_456,
  sweep_interval_ms: nil
