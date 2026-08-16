# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Database adapter configuration (compile-time)
# Use DATABASE_TYPE=postgres at compile time to use PostgreSQL adapter
database_adapter =
  case System.get_env("DATABASE_TYPE") do
    "postgres" -> Ecto.Adapters.Postgres
    "postgresql" -> Ecto.Adapters.Postgres
    _ -> Ecto.Adapters.SQLite3
  end

config :mydia,
  ecto_repos: [Mydia.Repo],
  generators: [timestamp_type: :utc_datetime],
  database_adapter: database_adapter

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
  version: "4.3.3",
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
  metadata: [
    :request_id,
    # Media and library metadata
    :media_item_id,
    :media_item_count,
    :media_type,
    :media_file_id,
    :media_file_ids,
    :library_path_id,
    :library_path,
    :library_type,
    :required_library_types,
    # Episode and season metadata
    :episode_id,
    :episode_number,
    :episode_count,
    :episode,
    :episodes,
    :parsed_episodes,
    :episode_season,
    :season_number,
    :season,
    :parsed_season,
    :season_pack_season,
    :current_episode,
    :current_season,
    :new_episode,
    :old_episode,
    :total_episodes,
    :missing_count,
    # Title and identification metadata
    :title,
    :series_title,
    :result_title,
    :local_title,
    :tmdb_id,
    :provider_id,
    :provider_type,
    # File and path metadata
    :path,
    :path1,
    :path2,
    :file,
    :file_id,
    :file_path,
    :file_paths,
    :filename,
    :new_path,
    :old_path,
    :dest,
    :source,
    :original,
    :directory,
    :recursive,
    :sample_paths,
    # Download and torrent metadata
    :download_id,
    :client,
    :client_id,
    :save_path,
    :torrent_id,
    :torrent_name,
    :confidence,
    # Counts and statistics
    :count,
    :file_count,
    :total_files,
    :files_found,
    :files_scanned,
    :new_files,
    :modified_files,
    :deleted_count,
    :completed_count,
    :failed_count,
    :items_processed,
    :shows_processed,
    :orphaned_files_fixed,
    :tv_orphans_fixed,
    # Search and matching metadata
    :query,
    :score,
    :match_score,
    :best_score,
    :breakdown,
    :total_results,
    :no_results,
    :searches_performed,
    :searches_for_show,
    :searches_this_season,
    :searches_so_far,
    :search_count,
    :max_searches_per_run,
    :max_searches_per_season,
    # Quality and technical metadata
    :resolution,
    :codec,
    :audio,
    :device,
    :device1,
    :device2,
    :quality_profile,
    # Status and results
    :reason,
    :error,
    :errors,
    :exception,
    :stacktrace,
    :success,
    :successful,
    :failed,
    :skipped,
    :found,
    :total,
    :exit_code,
    :output,
    # Time and progress metadata
    :duration_ms,
    :retention_days,
    :completed_at,
    :air_date,
    :position,
    :percentage,
    # Job and configuration metadata
    :args,
    :mode,
    :type,
    :id,
    :key,
    :value,
    :metadata,
    :delete_files,
    :year,
    :show,
    # Additional metadata keys
    :from,
    :to,
    :deleted_files,
    :episodes_count,
    :episodes_skipped,
    :missing_episodes,
    :missing_percentage,
    :parsed_episode,
    :parsed_info,
    :has_parsed_info,
    :has_media_file_id,
    :matches,
    :match_result_keys,
    :associations_updated,
    :available_libraries,
    :current_search_count,
    :searches_remaining,
    :seasons_remaining,
    :shows_remaining,
    :shows_skipped,
    :show_searches_used,
    :max_searches_per_show,
    :invalid_paths_removed,
    :untracked_matched,
    # The DownloadMonitor poll summary. These three travel together: a bare
    # `stall_update_failures=3` with no `stalled_count` beside it is a numerator
    # with no denominator, and cannot be read as 3-of-3 or 3-of-300.
    :stall_update_failures,
    :stalled_count,
    :stuck_count,
    :active_checked,
    :total_count,
    :media_item,
    :type_mismatches_detected,
    :movies_in_series_libs,
    :tv_in_movies_libs
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Guardian for JWT authentication
config :mydia, Mydia.Auth.Guardian,
  issuer: "mydia",
  ttl: {30, :days},
  allowed_drift: 2000,
  verify_issuer: true,
  secret_key: "REPLACE_IN_RUNTIME_CONFIG"

# Configure Guardian for media tokens (remote device access)
config :mydia, Mydia.RemoteAccess.MediaToken,
  issuer: "mydia",
  ttl: {24, :hours},
  allowed_drift: 2000,
  verify_issuer: true,
  secret_key: "REPLACE_IN_RUNTIME_CONFIG"

# Relay tunnel shared secret for defense-in-depth authentication
# Used to sign internal relay tunnel requests with HMAC-SHA256
# This provides additional security beyond localhost IP checks
config :mydia, :relay_tunnel_secret, "REPLACE_IN_RUNTIME_CONFIG"

# Configure Oban for background job processing
# Use Lite engine for SQLite, Basic engine for PostgreSQL
oban_engine =
  case database_adapter do
    Ecto.Adapters.Postgres -> Oban.Engines.Basic
    _ -> Oban.Engines.Lite
  end

config :mydia, Oban,
  repo: Mydia.Repo,
  engine: oban_engine,
  queues: [
    critical: 10,
    default: 5,
    media: 3,
    search: 2,
    analysis: 2,
    segments: 1,
    notifications: 1,
    maintenance: 1,
    import_lists: 2,
    integrations: 2,
    plugins: 1,
    # A user-started import can run for hours over a large library. It gets its
    # own single slot so it can never starve :media, which is only concurrency
    # 3 and also carries library, music and book scans.
    imports: 1
  ],
  plugins: [
    # Keep completed jobs for 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Scheduled jobs
    {Oban.Plugins.Cron,
     crontab: [
       # Tick scheduled plugins every minute (each plugin's manifest interval is
       # checked inside the job; due plugins get on-schedule). U4.
       {"* * * * *", Mydia.Jobs.PluginScheduler},
       # Monitor downloads every 2 minutes
       {"*/2 * * * *", Mydia.Jobs.DownloadMonitor},
       # Search for monitored movies every hour
       {"0 * * * *", Mydia.Jobs.MovieSearch, args: %{"mode" => "all_monitored"}},
       # Search for monitored TV shows every 30 minutes
       {"*/30 * * * *", Mydia.Jobs.TVShowSearch, args: %{"mode" => "all_monitored"}},
       # Clean up old events every Sunday at 2 AM
       {"0 2 * * 0", Mydia.Jobs.EventCleanup},
       # Sync Cardigann definitions daily at 3 AM
       {"0 3 * * *", Mydia.Jobs.DefinitionSync},
       # Check Cardigann indexer health every hour
       {"0 * * * *", Mydia.Jobs.CardigannHealthCheck},
       # Check for import lists due for sync every 15 minutes
       {"*/15 * * * *", Mydia.Jobs.ImportListScheduler},
       # Enqueue scans for library paths whose scan_interval has elapsed (opt-in per path)
       {"*/15 * * * *", Mydia.Jobs.LibraryScanScheduler},
       # Look for seasons needing intro/credits detection. The work itself runs
       # on the segments queue at concurrency 1, so this only ever queues.
       {"*/5 * * * *", Mydia.Jobs.SegmentDetectionScheduler},
       # Refresh metadata for all monitored items weekly on Sunday at 5 AM
       {"0 5 * * 0", Mydia.Jobs.MetadataRefresh, args: %{"refresh_all" => true}},
       # Repair media items stored with no metadata (blank posters) daily at 5:15 AM
       {"15 5 * * *", Mydia.Jobs.MetadataBackfill},
       # Permanently delete trashed media files past retention period daily at 5 AM
       {"0 5 * * *", Mydia.Jobs.TrashCleanup},
       # Sync runs accrue per server per user per tick, so they need pruning
       {"0 4 * * *", Mydia.Jobs.SyncRunCleanup},
       # Sync watched status with media servers every 30 minutes
       {"*/30 * * * *", Mydia.Jobs.MediaServerWatchedSync, args: %{"mode" => "all_enabled"}},
       # Purge expired release-blacklist rows daily at 5:30 AM (#123)
       {"30 5 * * *", Mydia.Jobs.BlacklistCleanup},
       # Analyze media files lacking tech metadata every minute (#131)
       {"* * * * *", Mydia.Jobs.FileAnalysis},
       # Check installed plugins for newer versions daily at 7 AM
       {"0 7 * * *", Mydia.Jobs.PluginUpdateCheck},
       # Prune per-invocation plugin debug logs daily at 4:30 AM (U5)
       {"30 4 * * *", Mydia.Jobs.PluginLogCleanup},
       # Look for quality upgrades to existing files daily at 1 AM. Deliberately
       # slower than the missing-file searches: this can touch the whole library.
       {"0 1 * * *", Mydia.Jobs.UpgradeSweep}
     ]}
  ]

# Event retention configuration
# Events older than this will be automatically deleted
config :mydia, :event_retention_days, 90

# Trash retention configuration
# Trashed media files older than this will be permanently deleted
config :mydia, :trash_retention_days, 30

# Trash directory. Trashed media files are moved off the library path so a
# library scan cannot resurrect them (see Mydia.Library.TrashStore). nil means
# "beside each library path", e.g. a library at /media/movies trashes into
# /media/.mydia-trash - outside the library, and normally on the same
# filesystem so the move is an atomic rename rather than a copy. Set
# MYDIA_TRASH_DIR to collect every library's trash in one directory instead;
# it must be outside all of your library paths.
config :mydia, :trash_dir, nil

# Automatic quality upgrade sweep configuration (see Mydia.Jobs.UpgradeSweep)
# lives entirely in the layered runtime config (lib/mydia/config/schema.ex,
# the :upgrades embed) rather than here — the job reads through
# Mydia.Config.get().upgrades so env/DB overrides actually take effect. See
# Mydia.Config.Schema.Upgrades for the defaults (sweep_enabled: true,
# sweep_batch_size: 50) and lib/mydia/config/loader.ex for the
# UPGRADE_SWEEP_ENABLED / UPGRADE_SWEEP_BATCH_SIZE env vars.

# HLS Streaming configuration
config :mydia, :streaming,
  # Session timeout (30 minutes of inactivity)
  session_timeout: :timer.minutes(30),
  # Temp directory for HLS segments
  temp_base_dir: "/tmp/mydia-hls",
  # Transcoding policy: :copy_when_compatible or :always
  # :copy_when_compatible - Use stream copy for compatible codecs (H.264/AAC) - 10-100x faster, zero quality loss
  # :always - Always re-encode (original behavior, slower but ensures consistent output)
  transcode_policy: :copy_when_compatible

# The transcode height ceiling is deliberately NOT here. This file is
# compile-time and baked into the release, so a key here is unreachable to an
# operator running the published image. It lives in the layered runtime config
# instead (lib/mydia/config/schema.ex, the :streaming embed), which makes it
# settable through MAX_TRANSCODE_HEIGHT, config.yml, or the settings UI. See
# Mydia.Streaming.FfmpegHlsTranscoder.effective_max_height/1.

# Episode monitor search limits
# Prevents excessive API usage that exhausts indexer quotas
config :mydia, :episode_monitor,
  # Max total searches across all shows per execution (prevents quota exhaustion)
  max_searches_per_run: 200,
  # Max searches for a single show per execution (ensures fair distribution)
  max_searches_per_show: 10,
  # Max searches for a single season per execution (limits season pack fallback impact)
  max_searches_per_season: 5,
  # Monitor special episodes (season 0) - default false due to low success rate (<5%)
  # Special episodes are rarely available on indexers and waste API quota
  # Set to true to search for specials, or search manually via UI
  monitor_special_episodes: false,
  # Delay between searches in milliseconds (prevents rapid-fire API calls)
  # Also used by movie search to throttle between movie searches
  # With 200 items × 3s delay = ~10 min per run, well within the 30-min interval
  search_delay_ms: 3000

# Auto-search release filtering
#
# NOTE: the minimum seeder count for automatic searches moved out of this
# compile-time block and into the layered runtime config as
# `downloads.min_seeders` (config.yml), settable at runtime from the admin
# settings UI or with the AUTO_SEARCH_MIN_SEEDERS environment variable. It
# still defaults to 0. See Mydia.Config.Schema.
config :mydia, :auto_search,
  # Case-insensitive substring tokens that disqualify a release title.
  # Default is empty — opt in by overriding in runtime.exs or releases.exs.
  # Examples for English-only libraries:
  #   blocked_release_tokens: ["UkrEng", "[DUB]", "Dragon Money", "Dual-Audio Russian"]
  # Tokens merge with any per-job `blocked_tags` passed in job args.
  blocked_release_tokens: []

# Indexer search throttling
# Controls concurrency and rate limiting for indexer queries
config :mydia, :indexer_search,
  # Max concurrent indexer requests per MANUAL search query. No value here on
  # purpose: Mydia.Indexers.search_all/2 defaults to searching every selected
  # indexer at once (capped at 16) unless a deployment explicitly sets
  # max_concurrency here, which still wins over that default. This used to be
  # hardcoded to 2 both here and in indexers.ex, which meant six 30s indexers
  # took 90 seconds even when every one of them was healthy. Manual search is
  # user-initiated and one at a time, so full fan-out is safe.
  #
  # Concurrency for UNATTENDED background searches (MovieSearch, TVShowSearch).
  # Deliberately low: see 02be582a, which reduced this from ~8 to 2 to stop
  # automatic searches getting users rate-limited and banned by indexer sites.
  # Manual searches do not use this; they fan out fully for latency.
  background_max_concurrency: 2,
  # Milliseconds before a single indexer is abandoned during an UNATTENDED
  # background search. Tighter than the 120s manual deadline on purpose: no
  # user is waiting, background jobs walk their items sequentially, and the
  # Oban :search queue has no execution timeout, so this is what bounds a
  # long sweep. See Mydia.Indexers.background_search_opts/0.
  background_deadline_ms: 60_000,
  # Default rate limit for Cardigann indexers (requests per minute per indexer)
  # Cardigann indexers hit sites directly, so conservative limits prevent bans
  default_cardigann_rate_limit: 3

# Feature flags
config :mydia, :features,
  # Enable/disable media playback feature (Play Movie, Play Episode buttons)
  # Enables HLS streaming for in-browser video playback with codec transcoding
  # Set to false to hide playback controls from the UI
  # Can be overridden via ENABLE_PLAYBACK environment variable
  playback_enabled: true,
  # Enable/disable Cardigann native indexer support
  # When enabled, provides access to hundreds of torrent indexers without external Prowlarr/Jackett
  # Set to false to disable Cardigann indexers
  # Can be overridden via ENABLE_CARDIGANN environment variable
  cardigann_enabled: true,
  # Enable/disable Import Lists feature
  # When enabled, shows the Import Lists UI for syncing external lists (TMDB watchlists, etc.)
  # Can be overridden via ENABLE_IMPORT_LISTS environment variable
  import_lists_enabled: false,
  # Enable/disable Remote Access feature (iroh-based peer-to-peer connectivity)
  # When enabled, starts the p2p server for remote device pairing and media streaming
  # Set to true to enable remote access functionality
  # Can be overridden via ENABLE_REMOTE_ACCESS environment variable
  remote_access_enabled: false

# P2P networking configuration (iroh)
# UDP port for direct peer-to-peer connections (enables hole punching)
# Required when running in Docker to allow direct connections without relay
# Set to nil for random port (works via relay but higher latency)
# Can be overridden via P2P_BIND_PORT environment variable
config :mydia, :p2p_bind_port, nil

# Path to store the P2P keypair for persistent node identity
# REQUIRED: Without this, the node ID changes on restart and paired devices can't reconnect
# Can be overridden via P2P_KEYPAIR_PATH environment variable
# Set in dev.exs for development, runtime.exs reads from env var for production
config :mydia, :p2p_keypair_path, nil

# Configure Ueberauth with empty providers by default
# This is overridden in dev.exs if OIDC is configured
config :ueberauth, Ueberauth, providers: []

# Configure ErrorTracker for local crash reporting
config :error_tracker,
  repo: Mydia.Repo,
  otp_app: :mydia,
  # Store crashes for 30 days
  prune_after: 30 * 24 * 60 * 60,
  # Enable in production and development, but not test
  enabled: config_env() != :test

# Configure crash reporter retry behavior
config :mydia, Mydia.CrashReporter.Queue,
  # Initial retry delay: 1 minute
  initial_retry_delay: 60_000,
  # Maximum retry delay: 8 minutes (exponential backoff caps here)
  max_retry_delay: 480_000,
  # Maximum retry attempts before giving up
  max_retries: 10,
  # Maximum total retry duration: 24 hours
  max_retry_duration: 24 * 60 * 60

# Configure Tower to capture genuine crashes only. `log_level: :none` disables
# Tower's plain-Logger-message capture entirely (it gates only the :message
# branch; crash capture via :crash_reason is unaffected), so routine
# Logger.error/warning calls are never reported to the relay.
config :tower,
  reporters: [Mydia.CrashReporter.TowerReporter],
  log_level: :none,
  logger_metadata: [:request_id]

# Configure downloads and transcoding
config :mydia, :downloads,
  transcode_cache_dir: "priv/data/transcodes",
  max_concurrent_transcodes: 2

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
