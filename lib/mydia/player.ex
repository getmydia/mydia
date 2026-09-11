defmodule Mydia.Player do
  @moduledoc """
  The one switch for everything that exists only to serve the Mydia player.

  `ENABLE_PLAYER` is read once, at boot, in `config/runtime.exs`. When it is
  false nothing player-only starts: the p2p node, pairing, HLS and transcode
  supervision, intro and credits detection, GraphQL subscriptions. The
  player's routes answer 404 and its UI is hidden.

  This switch sits outside the layered config (`Mydia.Config.Loader`), which
  every other setting goes through, and that is on purpose. It decides
  which processes exist, so it has to be known before the supervision tree is
  built, and the database layer cannot be read then. Starting and stopping the
  whole player live was judged not worth its cost.

  Two rules keep the switch honest:

    * A process that only serves the player is a child of
      `Mydia.Player.Supervisor`, never of `Mydia.Application.children/1`.
    * Code that still runs with the player off checks `enabled?/0` before it
      touches one of those processes.
  """

  require Logger

  @doc "Whether the player is on for this boot."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mydia, :player_enabled, true)

  @doc """
  Whether remote access is live. The one question every remote-access gate
  asks: media-token auth, the p2p request handlers, pairing. See
  `Mydia.Player.RemoteAccess.enabled?/0`.
  """
  @spec remote_access_enabled?() :: boolean()
  defdelegate remote_access_enabled?(), to: Mydia.Player.RemoteAccess, as: :enabled?

  @doc """
  Parses `ENABLE_PLAYER`. Unset or empty means on.

  Anything other than `true`, `false`, `1` or `0` raises, which stops boot. A
  typo in the switch that turns the player off must not leave it running.
  """
  @spec parse_env!(String.t() | nil) :: boolean()
  def parse_env!(nil), do: true
  def parse_env!(""), do: true
  def parse_env!(value) when value in ["true", "1"], do: true
  def parse_env!(value) when value in ["false", "0"], do: false

  def parse_env!(value) do
    raise ArgumentError,
          "ENABLE_PLAYER must be one of true, false, 1 or 0, got: #{inspect(value)}"
  end

  # Intro and credits detection is the only player-only job today.
  @player_cron_workers [Mydia.Jobs.SegmentDetectionScheduler]
  @player_queues [:segments]

  @doc """
  The player's slot in `Mydia.Application.children/1`: its supervisor, or
  nothing when the player is off.
  """
  @spec children() :: [module()]
  def children, do: if(enabled?(), do: [Mydia.Player.Supervisor], else: [])

  @doc """
  Removes the player's cron entries and queues from an Oban config when the
  player is off. The scheduler never fires and the queue never starts, so
  detection jobs already in the table wait, untouched, for the player to come
  back.
  """
  @spec prune_oban_config(keyword(), boolean()) :: keyword()
  def prune_oban_config(oban_config, enabled \\ enabled?())
  def prune_oban_config(oban_config, true), do: oban_config

  def prune_oban_config(oban_config, false) do
    oban_config
    |> prune_queues()
    |> prune_cron()
  end

  defp prune_queues(config) do
    case Keyword.fetch(config, :queues) do
      {:ok, queues} when is_list(queues) ->
        Keyword.put(config, :queues, Keyword.drop(queues, @player_queues))

      _ ->
        config
    end
  end

  defp prune_cron(config) do
    case Keyword.fetch(config, :plugins) do
      {:ok, plugins} when is_list(plugins) ->
        Keyword.put(config, :plugins, Enum.map(plugins, &prune_cron_plugin/1))

      _ ->
        config
    end
  end

  defp prune_cron_plugin({Oban.Plugins.Cron, opts}) do
    crontab = opts |> Keyword.get(:crontab, []) |> Enum.reject(&player_cron_entry?/1)
    {Oban.Plugins.Cron, Keyword.put(opts, :crontab, crontab)}
  end

  defp prune_cron_plugin(plugin), do: plugin

  defp player_cron_entry?({_expression, worker}), do: worker in @player_cron_workers
  defp player_cron_entry?({_expression, worker, _opts}), do: worker in @player_cron_workers
  defp player_cron_entry?(_entry), do: false

  @doc """
  Logs, once at boot, what the switch left out, and warns about the variable
  it replaced. `getenv` replaces `System.get_env/1` in tests.
  """
  @spec log_boot_state((String.t() -> String.t() | nil)) :: :ok
  def log_boot_state(getenv \\ &System.get_env/1) do
    if Mydia.Settings.env_var_set?("ENABLE_PLAYBACK", getenv) do
      Logger.warning(
        "ENABLE_PLAYBACK is no longer read. Use ENABLE_PLAYER=false to turn the player off."
      )
    end

    unless enabled?() do
      Logger.info(
        "Player disabled by ENABLE_PLAYER: p2p, pairing, streaming, offline-download " <>
          "transcodes, intro and credits detection and the player UI are off"
      )
    end

    :ok
  end
end
