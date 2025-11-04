# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mydia,
  ecto_repos: [Mydia.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :mydia, MydiaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MydiaWeb.ErrorHTML, json: MydiaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mydia.PubSub,
  live_view: [signing_salt: "fUhVwVhL"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mydia: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  mydia: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Guardian for JWT authentication
config :mydia, Mydia.Auth.Guardian,
  issuer: "mydia",
  ttl: {30, :days},
  allowed_drift: 2000,
  verify_issuer: true,
  secret_key: "REPLACE_IN_RUNTIME_CONFIG"

# Configure Oban for background job processing
# Using Lite engine with polling for SQLite compatibility
config :mydia, Oban,
  repo: Mydia.Repo,
  engine: Oban.Engines.Lite,
  queues: [
    critical: 10,
    default: 5,
    media: 3,
    search: 2,
    notifications: 1
  ],
  plugins: [
    # Keep completed jobs for 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Scheduled jobs
    {Oban.Plugins.Cron,
     crontab: [
       # Scan library every hour
       {"0 * * * *", Mydia.Jobs.LibraryScanner},
       # Monitor downloads every 2 minutes
       {"*/2 * * * *", Mydia.Jobs.DownloadMonitor}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
