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

  @doc "Whether the player is on for this boot."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mydia, :player_enabled, true)

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
end
