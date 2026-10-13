defmodule Mydia.Indexers.SearchStats.Event do
  @moduledoc """
  One indexer call, as recorded by `Mydia.Indexers.SearchStats.Recorder`.

  Built from a `Mydia.Indexers.SearchStats.Telemetry` event. Every atom in the
  metadata is stored as a string so the table reads the same on SQLite and
  PostgreSQL. Rows live 14 days.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @max_message 500

  @type t :: %__MODULE__{}

  schema "indexer_search_events" do
    field :indexer_id, :string
    field :indexer_name, :string
    field :indexer_type, :string
    field :engine, :string
    field :kind, :string
    field :outcome, :string
    field :error_message, :string
    field :duration_ms, :integer
    field :network_ms, :integer
    field :result_count, :integer
    field :inserted_at, :utc_datetime_usec
  end

  @doc "Builds an unsaved row from a telemetry event's measurements and metadata."
  @spec from_telemetry(map(), map()) :: t()
  def from_telemetry(measurements, metadata) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      indexer_id: to_string(metadata[:indexer_id] || metadata[:indexer_name] || "unknown"),
      indexer_name: to_string(metadata[:indexer_name] || "unknown"),
      indexer_type: to_string(metadata[:indexer_type] || "unknown"),
      engine: optional_string(metadata[:engine]),
      kind: to_string(metadata[:kind] || "search"),
      outcome: to_string(metadata[:outcome] || "unknown"),
      error_message: truncate(metadata[:error_message]),
      duration_ms: native_to_ms(measurements[:duration]) || 0,
      network_ms: native_to_ms(measurements[:network]),
      result_count: measurements[:result_count] || 0,
      inserted_at: DateTime.utc_now()
    }
  end

  @doc "The plain map `Repo.insert_all/3` takes for this row."
  @spec row(t()) :: map()
  def row(%__MODULE__{} = event), do: Map.take(event, __schema__(:fields))

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp truncate(nil), do: nil
  defp truncate(message), do: message |> to_string() |> String.slice(0, @max_message)

  defp native_to_ms(nil), do: nil
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
