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
  rendezvous_master_pepper: "test-pepper-not-for-production",
  p2p_access_bearer_tokens: ["test-relay-bearer"],
  # The P2pAccess.Store's timers would otherwise fire mid-suite and write to
  # the database from a process that does not own the sandbox connection.
  # Pin them well beyond any plausible suite runtime; tests drive the work
  # explicitly through flush_now/0, prune_now/0 and a direct :reload_blocks.
  p2p_flush_interval_ms: 3_600_000,
  p2p_prune_interval_ms: 3_600_000,
  p2p_reload_retry_interval_ms: 3_600_000

config :metadata_relay, MetadataRelay.Feedback.Notifier,
  recipient: "maintainer@example.com",
  from: "metadata-relay@example.com",
  dashboard_url: "https://relay.example.com"

config :metadata_relay, MetadataRelay.Mailer, adapter: Swoosh.Adapters.Test
