defmodule MetadataRelay.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4000"))

    children = [
      # In-memory cache with ETS
      MetadataRelay.CacheServer,
      # TVDB authentication GenServer
      MetadataRelay.TVDB.Auth,
      # HTTP server with Bandit
      {Bandit, plug: MetadataRelay.Router, scheme: :http, port: port}
    ]

    opts = [strategy: :one_for_one, name: MetadataRelay.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
