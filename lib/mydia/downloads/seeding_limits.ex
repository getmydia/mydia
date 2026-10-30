defmodule Mydia.Downloads.SeedingLimits do
  @moduledoc """
  Pushes a tracker's seeding goal into the download client at grab, so the
  client itself stops seeding once the goal is met.

  Best effort: a failure is logged and the grab goes on. The removal guard
  (`Mydia.Downloads.ClientRemoval.terms_met?/2`) applies either way, so a
  client that refused or ignored the limits still keeps the torrent until
  the goal is met.

  Which clients take limits is up to the adapter's optional
  `c:Mydia.Downloads.Client.set_share_limits/3`: qBittorrent takes the ratio
  and the seed time, Transmission the ratio only, and the rest nothing.
  """

  require Logger

  alias Mydia.Downloads.Client
  alias Mydia.Indexers.Structs.TrackerTerms

  @doc """
  Sends `terms`' minimum ratio and seed time to the torrent `client_id`.

  Returns `:ok`, `:skipped` when the terms set neither, `:unsupported` when
  the adapter takes no limits, or `{:error, reason}` after logging it.
  """
  @spec push(module() | nil, map(), String.t(), TrackerTerms.t() | nil) ::
          :ok | :skipped | :unsupported | {:error, term()}
  def push(adapter, config, client_id, terms) do
    case limits(terms) do
      nil -> :skipped
      limits -> send_limits(adapter, config, client_id, limits)
    end
  end

  defp limits(%TrackerTerms{minimum_ratio: nil, minimum_seed_time: nil}), do: nil

  defp limits(%TrackerTerms{} = terms),
    do: %{ratio: terms.minimum_ratio, seed_time: terms.minimum_seed_time}

  defp limits(nil), do: nil

  defp send_limits(adapter, config, client_id, limits) do
    case Client.set_share_limits(adapter, config, client_id, limits) do
      :ok ->
        Logger.info("Pushed tracker share limits to the download client",
          client_id: client_id,
          ratio: limits.ratio,
          seed_time: limits.seed_time
        )

        :ok

      {:error, :unsupported} ->
        :unsupported

      {:error, reason} ->
        Logger.warning("Could not push tracker share limits; the removal guard still applies",
          client_id: client_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end
