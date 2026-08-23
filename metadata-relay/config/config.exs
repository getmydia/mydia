import Config

# Configure the application
config :metadata_relay,
  # Default port for HTTP server
  port: 4000,
  # Ecto repository
  ecto_repos: [MetadataRelay.Repo],
  dashboard_auth: [username: "admin", password: "admin"],
  # Off unless RELAY_PROXY_RATE_LIMIT says otherwise. Behind Cloudflare the
  # resolvable client IP is a shared Cloudflare edge address, so enabling
  # this before the origin is restricted to Cloudflare's ranges would 429
  # unrelated installs. See MetadataRelay.Plug.ProxyRateLimit's moduledoc.
  proxy_rate_limit_enabled: false

config :metadata_relay, MetadataRelay.Feedback.Notifier,
  recipient: nil,
  from: "metadata-relay@localhost",
  dashboard_url: nil

config :metadata_relay, MetadataRelay.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, false

# Configure Phoenix endpoint for ErrorTracker dashboard
config :metadata_relay, MetadataRelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MetadataRelayWeb.Layouts],
    layout: false
  ],
  pubsub_server: MetadataRelay.PubSub,
  live_view: [signing_salt: "error_tracker_lv_salt"],
  secret_key_base:
    "metadata_relay_secret_key_base_placeholder_needs_to_be_at_least_64_bytes_long_for_security"

config :esbuild,
  version: "0.25.4",
  metadata_relay: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.18",
  metadata_relay: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure ErrorTracker
config :error_tracker,
  repo: MetadataRelay.Repo,
  otp_app: :metadata_relay,
  enabled: true

# Configure the logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"
