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
        Mydia.Metadata.Provider.Registry
      ] ++
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
      # Register indexer adapters after supervisor has started
      Mydia.Indexers.register_adapters()
      # Register metadata provider adapters
      Mydia.Metadata.register_providers()
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
    if Mix.env() in [:prod, :staging] or System.get_env("LOAD_RUNTIME_CONFIG") == "true" do
      Mydia.Config.Loader.load!()
    else
      # In dev/test, use schema defaults to avoid interfering with Mix config
      Mydia.Config.Schema.defaults()
    end
  end
end
