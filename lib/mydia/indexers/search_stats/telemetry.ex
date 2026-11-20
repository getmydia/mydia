defmodule Mydia.Indexers.SearchStats.Telemetry do
  @moduledoc """
  `[:mydia, :indexers, :search, :stop]`: one indexer call settled.

  Emitted by `Mydia.Indexers.search_all/2` for every indexer it searched,
  including tasks killed by the search deadline, and by
  `Mydia.Indexers.CardigannHealthCheck` for every probe.

  Measurements: `duration` (native), `result_count`, `network` (native)
  when the Prowlarr engine measured its host HTTP time, and `http_requests`
  when the call sent any request to the tracker
  (`Mydia.Indexers.SearchStats.Network`).

  Metadata: `indexer_id`, `indexer_name`, `indexer_type`, `engine`
  (`:builtin` or `:prowlarr` for Cardigann, otherwise nil), `kind` (`:search`
  or `:health`), `outcome` (`:ok`, an `Adapter.Error` type, `:skipped_cooldown`,
  `:skipped_local_limit` or `:skipped_daily_cap` for a search Mydia chose not
  to send, `:deadline`, `:crashed`, or a health status), `error_message`.
  """

  alias Mydia.Indexers.Cardigann.EngineSwitcher

  @event [:mydia, :indexers, :search, :stop]

  @spec event() :: [atom()]
  def event, do: @event

  @spec emit(map(), keyword()) :: :ok
  def emit(config, opts) do
    measurements =
      %{
        duration: ms_to_native(Keyword.fetch!(opts, :duration_ms)),
        result_count: Keyword.get(opts, :result_count, 0)
      }
      |> put_network(Keyword.get(opts, :network_ms))
      |> put_requests(Keyword.get(opts, :http_requests))

    type = Map.get(config, :type)

    :telemetry.execute(@event, measurements, %{
      indexer_id: Map.get(config, :id),
      indexer_name: Map.get(config, :name),
      indexer_type: type,
      engine: engine(type),
      kind: Keyword.fetch!(opts, :kind),
      outcome: Keyword.fetch!(opts, :outcome),
      error_message: Keyword.get(opts, :error_message)
    })
  end

  defp engine(:cardigann), do: EngineSwitcher.active()
  defp engine(_type), do: nil

  defp put_network(measurements, nil), do: measurements
  defp put_network(measurements, ms), do: Map.put(measurements, :network, ms_to_native(ms))

  defp put_requests(measurements, nil), do: measurements
  defp put_requests(measurements, count), do: Map.put(measurements, :http_requests, count)

  defp ms_to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end
