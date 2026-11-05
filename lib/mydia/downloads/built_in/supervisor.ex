defmodule Mydia.Downloads.BuiltIn.Supervisor do
  @moduledoc """
  Starts the built-in torrent client when `Config` says it is enabled.

  `rest_for_one`: if `Status` restarts, the engine and the VPN gate restart
  with it, so nothing reports into a fresh, empty status.
  """

  use Supervisor
  require Logger

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status, Vpn}

  # The engine's terminate waits up to 10s for rqbit to exit.
  @engine_shutdown_ms 15_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # The built-in client is on by default, so nothing it does at boot may
    # take the application down with it.
    children =
      try do
        build_children(opts)
      rescue
        e ->
          Logger.error("built-in torrent client not started: #{Exception.message(e)}")
          BuiltIn.clear_runtime()
          []
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_children(opts) do
    config = Config.load(System.get_env(), other_client_types())
    credentials = {"mydia", Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
    api_port = Keyword.get(opts, :api_port, 3030)

    # Never leave an entry from an earlier start behind when this one is off.
    if config.enabled? do
      BuiltIn.put_runtime(%{api_port: api_port, credentials: credentials, config: config})
    else
      BuiltIn.clear_runtime()
    end

    children(config, Keyword.merge(opts, credentials: credentials, api_port: api_port))
  end

  @spec children(Config.t(), keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(%Config{enabled?: false}, _opts), do: []

  def children(%Config{} = config, opts) do
    engine =
      Supervisor.child_spec(
        {Engine,
         config: config,
         credentials: Keyword.fetch!(opts, :credentials),
         api_port: Keyword.get(opts, :api_port, 3030),
         rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
         autostart: not config.vpn?},
        shutdown: @engine_shutdown_ms
      )

    base = [{Status, warnings: config.warnings}, engine]
    if config.vpn?, do: base ++ [{Vpn, config: config}], else: base
  end

  # Types of the clients configured other than the built-in one: database rows
  # plus DOWNLOAD_CLIENT_<N>_* blocks. The built-in client is rejected
  # explicitly: after a supervisor restart it is already in the runtime list,
  # and counting it as an rqbit client would switch it off.
  defp other_client_types do
    Mydia.Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.reject(&BuiltIn.managed?(%{connection_settings: &1.connection_settings}))
    |> Enum.map(& &1.type)
    |> Enum.filter(&(&1 in Config.torrent_types()))
  rescue
    e ->
      Logger.warning(
        "could not read the download clients, leaving the built-in torrent client off unless MYDIA_TORRENT_ENABLED=true: #{Exception.message(e)}"
      )

      :unknown
  end
end
