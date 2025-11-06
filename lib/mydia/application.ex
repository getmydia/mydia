defmodule Mydia.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load and validate configuration at startup
    config = load_config!()

    # Store validated config in Application environment for fast access
    Application.put_env(:mydia, :runtime_config, config)

    children =
      [
        MydiaWeb.Telemetry,
        Mydia.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:mydia, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:mydia, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Mydia.PubSub},
        Mydia.Downloads.Client.Registry,
        Mydia.Indexers.Adapter.Registry,
        Mydia.Indexers.RateLimiter,
        Mydia.Metadata.Provider.Registry,
        Mydia.Metadata.Cache,
        {Task.Supervisor, name: Mydia.TaskSupervisor},
        Mydia.Hooks.Manager
      ] ++
        client_health_children() ++
        indexer_health_children() ++
        oban_children() ++
        [
          # Start a worker by calling: Mydia.Worker.start_link(arg)
          # {Mydia.Worker, arg},
          # Start to serve requests, typically the last entry
          MydiaWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mydia.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Register download client adapters after supervisor has started
      Mydia.Downloads.register_clients()
      # Register indexer adapters after supervisor has started
      Mydia.Indexers.register_adapters()
      # Register metadata provider adapters
      Mydia.Metadata.register_providers()
      # Ensure default quality profiles exist (skip in test environment)
      if Application.get_env(:mydia, :start_health_monitors, true) do
        ensure_default_quality_profiles()
        validate_library_paths()
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

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp load_config! do
    # Only load runtime config in non-dev/test environments
    # or if explicitly enabled via environment variable
    # In releases, Mix is not available, so we check for RELEASE_NAME
    env = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod

    if env in [:prod, :staging] or System.get_env("LOAD_RUNTIME_CONFIG") == "true" do
      Mydia.Config.Loader.load!()
    else
      # In dev/test, use schema defaults to avoid interfering with Mix config
      Mydia.Config.Schema.defaults()
    end
  end

  defp ensure_default_quality_profiles do
    case Mydia.Settings.ensure_default_quality_profiles() do
      {:ok, count} when count > 0 ->
        IO.puts("✓ Created #{count} default quality profile(s)")

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
end
