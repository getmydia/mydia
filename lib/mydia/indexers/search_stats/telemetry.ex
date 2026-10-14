defmodule Mydia.Indexers.SearchStats.Telemetry do
  @moduledoc """
  `[:mydia, :indexers, :search, :stop]`: one indexer call settled.

  Emitted by `Mydia.Indexers.search_all/2` for every indexer it searched,
  including tasks killed by the search deadline, and by
  `Mydia.Indexers.CardigannHealthCheck` for every probe.

  Measurements: `duration` (native), `result_count`, and `network` (native)
  when the Prowlarr engine measured its host HTTP time.

  Metadata: `indexer_id`, `indexer_name`, `indexer_type`, `engine`
  (`:builtin` or `:prowlarr` for Cardigann, otherwise nil), `kind` (`:search`
  or `:health`), `outcome` (`:ok`, an `Adapter.Error` type, `:deadline`,
  `:crashed`, or a health status), `error_message`.
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

  defp ms_to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end
