defmodule Mydia.Downloads.BuiltIn.Supervisor do
  @moduledoc """
  One running instance of the built-in torrent client: `Status`, `Engine`,
  with the VPN on the `Vpn` gate, and `Limits`.

  `Mydia.Downloads.BuiltIn.Manager` decides what runs and starts this tree
  under a `DynamicSupervisor`, replacing the whole tree whenever the effective
  config changes. The tree only builds its children from the options it is
  given; it reads no environment and stores nothing globally.

  `rest_for_one`: if `Status` restarts, the engine and the VPN gate restart
  with it, so nothing reports into a fresh, empty status. `Limits` comes last,
  so a crash there restarts nothing else, least of all the VPN gate; it
  catches up on a status it missed when it starts.

  Options: `:config` (a `Config`, required), `:credentials` (required),
  `:api_port` (default `config.api_port`), `:expected_hash` (the settings file
  hash the `Vpn` gate waits for) and `:rqbit_path` (default `"rqbit"`).
  """

  use Supervisor

  alias Mydia.Downloads.BuiltIn.{Config, Engine, Limits, Status, Vpn}

  # The engine's terminate waits up to 10s for rqbit to exit.
  @engine_shutdown_ms 15_000

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    opts |> Keyword.fetch!(:config) |> children(opts) |> Supervisor.init(strategy: :rest_for_one)
  end

  @spec children(Config.t(), keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(%Config{enabled?: false}, _opts), do: []

  def children(%Config{} = config, opts) do
    engine =
      Supervisor.child_spec(
        {Engine,
         config: config,
         credentials: Keyword.fetch!(opts, :credentials),
         api_port: Keyword.get(opts, :api_port, config.api_port),
         rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
         autostart: not config.vpn?},
        shutdown: @engine_shutdown_ms
      )

    vpn =
      if config.vpn?,
        do: [{Vpn, config: config, expected_hash: Keyword.get(opts, :expected_hash)}],
        else: []

    [{Status, warnings: config.warnings}, engine] ++ vpn ++ [{Limits, config: config}]
  end
end
