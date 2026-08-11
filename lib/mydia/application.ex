defmodule Mydia.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  # Check if running in CLI mode (quiet startup)
  defp cli_mode?, do: System.get_env("MYDIA_CLI_MODE") == "true"

  @impl true
  def start(_type, _args) do
    # Suppress logger output in CLI mode
    if cli_mode?(), do: Logger.configure(level: :error)

    # Create ETS tables before supervision tree for O(1) token lookups
    create_ets_tables()

    # Load and validate configuration at startup
    config = load_config!()

    # Store validated config in Application environment for fast access
    Application.put_env(:mydia, :runtime_config, config)

    children =
      [
        MydiaWeb.Telemetry,
        Mydia.Repo,
        # Backs up the database before the migrator touches it. Needs a live Repo
        # to ask whether migrations are pending, so it sits between the two, and
        # returns :ignore once done rather than lingering as a process.
        {Mydia.Release.MigrationBackup, skip: skip_migrations?()},
        {Ecto.Migrator,
         repos: Application.fetch_env!(:mydia, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:mydia, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Mydia.PubSub},
        Mydia.Downloads.Client.Registry,
        # Owns the ETS table holding the derived set of client torrents Mydia
        # does not manage. init/1 only creates the table (no I/O), so unlike
        # ClientHealth this is safe to start in every environment.
        Mydia.Downloads.ExternalTorrents,
        Mydia.Indexers.Adapter.Registry,
        Mydia.Indexers.RateLimiter,
        Mydia.Metadata.Provider.Registry,
        Mydia.Metadata.Cache,
        Mydia.Metadata.ProviderIDRegistry,
        {Task.Supervisor, name: Mydia.TaskSupervisor},
        # Request task supervisor for multiplexed request handling with independent timeouts
        {Task.Supervisor, name: Mydia.RequestTaskSupervisor},
        # Supervises optimistic manual-grab pipelines (Mydia.Downloads.Grabber)
        # so grabs survive the LiveView that started them.
        {Task.Supervisor, name: Mydia.Downloads.GrabSupervisor},
        # WASM plugin platform: per-plugin pools register here and live under
        # the dynamic supervisor (see Mydia.Plugins.Host); the Agent registry
        # holds installed plugin descriptors (see Mydia.Plugins.Registry).
        Mydia.Plugins.Registry,
        {Registry, keys: :unique, name: Mydia.Plugins.PoolRegistry},
        {DynamicSupervisor, name: Mydia.Plugins.PoolSupervisor, strategy: :one_for_one},
        # Per-plugin invocation single-flight lock (U4): serializes on-event /
        # on-schedule / inline calls for one plugin so shared KV state is safe.
        Mydia.Plugins.SingleFlight,
        # Fans "events:all" out to subscribed plugins (U5). Replaces the Luerl
        # hooks manager removed in U11.
        Mydia.Plugins.Dispatcher,
        {Registry, keys: :unique, name: Mydia.Streaming.HlsSessionRegistry},
        Mydia.Streaming.HlsSessionSupervisor,
        {Registry, keys: :unique, name: Mydia.Downloads.TranscodeRegistry},
        {Registry, keys: :unique, name: Mydia.Downloads.Client.Debrid.FetcherRegistry},
        {DynamicSupervisor,
         name: Mydia.Downloads.Client.Debrid.FetcherSupervisor, strategy: :one_for_one},
        Mydia.Downloads.Client.Debrid.RateLimiter,
        {Registry, keys: :unique, name: Mydia.Downloads.Seedbox.FetcherRegistry},
        {DynamicSupervisor,
         name: Mydia.Downloads.Seedbox.FetcherSupervisor, strategy: :one_for_one},
        Mydia.Downloads.JobManager,
        Mydia.CrashReporter.Throttle,
        Mydia.CrashReporter.Queue,
        Mydia.RemoteAccess.ClaimRateLimiter,
        Mydia.Accounts.ApiKeyRateLimiter,
        {Registry, keys: :unique, name: Mydia.DynamicSupervisorRegistry},
        {DynamicSupervisor,
         name: {:via, Registry, {Mydia.DynamicSupervisorRegistry, :relay}}, strategy: :one_for_one}
      ] ++
        remote_access_children() ++
        client_health_children() ++
        indexer_health_children() ++
        relay_children() ++
        oban_children() ++
        oidc_children() ++
        [
          # Start a worker by calling: Mydia.Worker.start_link(arg)
          # {Mydia.Worker, arg},
          # Start to serve requests, typically the last entry
          MydiaWeb.Endpoint,
          # Absinthe subscriptions must start after the Endpoint
          {Absinthe.Subscription, MydiaWeb.Endpoint}
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mydia.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Crash capture is handled by Tower (see Mydia.CrashReporter.TowerReporter),
      # which auto-attaches its :logger handler on application start.

      # Reset any jobs stuck in executing state from previous runs
      reset_stale_jobs()
      # Attach Oban job broadcaster for real-time job status updates
      Mydia.Jobs.Broadcaster.attach()
      # Register download client adapters after supervisor has started
      Mydia.Downloads.register_clients()
      # Register indexer adapters after supervisor has started
      Mydia.Indexers.register_adapters()
      # Register metadata provider adapters
      Mydia.Metadata.register_providers()
      # Own the Plex endpoint cache here so its ETS table outlives the request
      # or job process that happens to resolve an endpoint first
      Mydia.MediaServer.Plex.Endpoint.init_cache()
      # Rehydrate installed WASM plugins into the runtime registry
      Mydia.Plugins.register_plugins()
      # Start relay service if remote access is enabled (requires Repo to be running)
      start_relay_if_enabled()
      # Ensure default quality profiles exist (skip in test environment)
      if Application.get_env(:mydia, :start_health_monitors, true) do
        ensure_default_quality_profiles()
        validate_library_paths()
        # Sync library paths and populate relative paths for media files
        Mydia.Library.StartupSync.sync_all()
        # Check for database integrity issues and queue repairs if needed
        Mydia.Library.DatabaseHealthCheck.run()
        # Clean up stale HLS session directories
        cleanup_stale_hls_sessions()
      end

      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MydiaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp remote_access_children do
    # Only start P2P server and related processes if remote access is enabled
    if Application.get_env(:mydia, :features)[:remote_access_enabled] do
      [
        Mydia.P2p.Server,
        # Resume active pairing claims on startup
        Mydia.RemoteAccess.ResumeClaims
      ]
    else
      []
    end
  end

  defp client_health_children do
    # Don't start ClientHealth in test environment to avoid SQL Sandbox conflicts
    if Application.get_env(:mydia, :start_health_monitors, true) do
      [Mydia.Downloads.ClientHealth]
    else
      []
    end
  end

  defp indexer_health_children do
    # Don't start IndexerHealth in test environment to avoid SQL Sandbox conflicts
    if Application.get_env(:mydia, :start_health_monitors, true) do
      [Mydia.Indexers.Health]
    else
      []
    end
  end

  defp relay_children do
    # Relay is started dynamically after supervisor starts (see start_relay_if_enabled/0)
    # This avoids querying the database before Repo is started
    []
  end

  # Legacy relay service startup - no longer needed with P2P architecture.
  # The Mydia.P2p.Server is now started in the supervision tree and handles
  # all P2P connectivity for remote access.
  defp start_relay_if_enabled do
    :ok
  end

  defp oban_children do
    # Don't start Oban in test environment to avoid pool conflicts with SQL Sandbox
    oban_config = Application.get_env(:mydia, Oban, [])

    # Skip Oban if testing is manual or queues are disabled
    if Keyword.get(oban_config, :testing) == :manual or
         Keyword.get(oban_config, :queues) == false do
      []
    else
      [{Oban, oban_config}]
    end
  end

  defp oidc_children do
    # Start OIDC provider configuration workers if configured in runtime.exs
    # This is needed because UeberauthOidcc.Application starts before runtime.exs runs,
    # so the issuers config is not available when it starts. We need to start the
    # provider workers ourselves after runtime.exs has set the configuration.
    #
    # However, in releases where runtime.exs runs before the app starts, the library
    # may already start the workers. We check if they're already running to avoid
    # "already started" errors.
    case Application.get_env(:ueberauth_oidcc, :issuers) do
      nil ->
        []

      [] ->
        []

      issuers when is_list(issuers) ->
        # Filter out issuers whose workers are already running
        issuers_to_start =
          Enum.reject(issuers, fn child_opts ->
            name = Map.fetch!(child_opts, :name)
            # Check if the worker is already registered
            case Process.whereis(name) do
              nil -> false
              _pid -> true
            end
          end)

        if issuers_to_start == [] do
          Logger.info("OIDC provider workers already running (started by library)")
          []
        else
          Logger.info(
            "Starting OIDC provider configuration workers for #{length(issuers_to_start)} issuer(s)"
          )

          for child_opts <- issuers_to_start do
            name = Map.fetch!(child_opts, :name)
            child_opts = Map.put_new(child_opts, :backoff_type, :random)
            Logger.info("  - Starting OIDC provider: #{inspect(name)}")
            Supervisor.child_spec({Oidcc.ProviderConfiguration.Worker, child_opts}, id: name)
          end
        end
    end
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp load_config! do
    Mydia.Config.Loader.load!()
  end

  defp ensure_default_quality_profiles do
    case Mydia.Settings.ensure_default_quality_profiles() do
      {:ok, count} when count > 0 ->
        unless cli_mode?(), do: IO.puts("✓ Created #{count} default quality profile(s)")

      {:ok, 0} ->
        :ok

      {:error, _reason} ->
        # Database not ready yet, profiles will be created on next startup
        :ok
    end
  end

  defp validate_library_paths do
    # Validate library paths from runtime configuration
    config = Application.get_env(:mydia, :runtime_config, Mydia.Config.Schema.defaults())

    paths_to_validate = []

    # Check movies_path if configured
    paths_to_validate =
      if is_struct(config) and Map.has_key?(config, :media) and config.media.movies_path do
        [{config.media.movies_path, "movies"} | paths_to_validate]
      else
        paths_to_validate
      end

    # Check tv_path if configured
    paths_to_validate =
      if is_struct(config) and Map.has_key?(config, :media) and config.media.tv_path do
        [{config.media.tv_path, "TV shows"} | paths_to_validate]
      else
        paths_to_validate
      end

    # Validate each path
    validation_results =
      Enum.map(paths_to_validate, fn {path, media_type} ->
        validate_single_path(path, media_type)
      end)

    # Report validation results
    errors =
      Enum.filter(validation_results, fn {status, _path, _media_type, _reason} ->
        status == :error
      end)

    warnings =
      Enum.filter(validation_results, fn {status, _path, _media_type, _reason} ->
        status == :warning
      end)

    unless cli_mode?() do
      if errors != [] do
        IO.puts("\n⚠️  Library Path Validation Errors:")

        Enum.each(errors, fn {:error, path, media_type, reason} ->
          IO.puts("  ✗ #{media_type} path '#{path}': #{reason}")
        end)

        IO.puts("\nPlease fix these paths in your configuration file or environment variables.")
      end

      if warnings != [] do
        IO.puts("\n⚠️  Library Path Validation Warnings:")

        Enum.each(warnings, fn {:warning, path, media_type, reason} ->
          IO.puts("  ! #{media_type} path '#{path}': #{reason}")
        end)
      end

      if errors == [] and warnings == [] and paths_to_validate != [] do
        IO.puts("✓ All library paths validated successfully")
      end
    end

    # Return validation status
    if errors != [] do
      {:error, :invalid_library_paths}
    else
      :ok
    end
  end

  defp validate_single_path(path, media_type) do
    cond do
      is_nil(path) or path == "" ->
        {:warning, path, media_type, "path is not configured"}

      not File.exists?(path) ->
        {:error, path, media_type, "path does not exist"}

      not File.dir?(path) ->
        {:error, path, media_type, "path exists but is not a directory"}

      true ->
        # Check if path is readable
        case File.ls(path) do
          {:ok, _} ->
            {:ok, path, media_type, "valid"}

          {:error, reason} ->
            {:error, path, media_type, "path exists but is not readable: #{inspect(reason)}"}
        end
    end
  end

  defp cleanup_stale_hls_sessions do
    # Cleanup DB records for streaming jobs
    Mydia.Downloads.delete_all_streaming_jobs()

    case Mydia.Streaming.HlsCleanup.cleanup_stale_sessions() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        unless cli_mode?(), do: IO.puts("✓ Cleaned up #{count} stale HLS session directory(ies)")

      {:error, _reason} ->
        # Don't fail startup on cleanup errors
        :ok
    end
  end

  defp reset_stale_jobs do
    # Only reset stale jobs if Oban is configured to run
    oban_config = Application.get_env(:mydia, Oban, [])

    if Keyword.get(oban_config, :testing) != :manual and
         Keyword.get(oban_config, :queues) != false do
      case Mydia.Jobs.reset_stale_executing_jobs() do
        {:ok, 0} ->
          :ok

        {:ok, count} ->
          unless cli_mode?(), do: IO.puts("✓ Reset #{count} stale job(s) to available state")
      end
    end
  end

  defp create_ets_tables do
    # Create ETS tables for O(1) media token lookups
    # These must be created before the supervision tree starts
    Mydia.Media.TokenCache.create_table()
  end
end
