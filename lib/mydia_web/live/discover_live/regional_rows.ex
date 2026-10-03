defmodule MydiaWeb.DiscoverLive.RegionalRows do
  @moduledoc """
  Row state for the Discover country tab's landing view.

  `:regional_rows` maps a source param to `%{status, items}`. Each row loads
  in its own `start_async` keyed `{:regional_row, media_type, param}`, so one
  slow or failing row never holds up the others, and a result that arrives
  after the user switched Movies/TV is dropped instead of landing in the
  wrong row.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Mydia.Media.RemoteFilter
  alias Mydia.Metadata.RegionalSources

  @doc "Starts every row for the current sources."
  def load_all(socket) do
    rows =
      Map.new(socket.assigns.regional_sources, fn source ->
        {RegionalSources.to_param(source), %{status: :loading, items: []}}
      end)

    socket = assign(socket, :regional_rows, rows)
    Enum.reduce(Map.keys(rows), socket, &load(&2, &1))
  end

  @doc "Starts (or restarts) one row."
  def load(socket, param) do
    %{media_type: media_type, home_country: country, current_scope: scope} = socket.assigns

    case RegionalSources.find(socket.assigns.regional_sources, param) do
      nil ->
        socket

      source ->
        extra =
          scope
          |> RemoteFilter.discover_params(media_type)
          |> Keyword.take([:certification_country, :certification_lte])

        today = Date.utc_today()

        socket
        |> put_row(param, %{status: :loading, items: []})
        |> start_async({:regional_row, media_type, param}, fn ->
          RegionalSources.fetch(source, media_type, country, extra, today)
        end)
    end
  end

  @doc """
  Stores a row's result. `enrich` turns raw results into display items
  (restriction filter, library and request status).
  """
  def put_result(socket, media_type, param, result, enrich) do
    cond do
      media_type != socket.assigns.media_type -> socket
      not Map.has_key?(socket.assigns.regional_rows, param) -> socket
      true -> put_row(socket, param, row_for(result, enrich))
    end
  end

  defp row_for({:ok, {:ok, results}}, enrich), do: %{status: :ok, items: enrich.(results)}
  defp row_for(_error_or_exit, _enrich), do: %{status: :error, items: []}

  @doc "Every row's items, for lookups by id."
  def item_lists(assigns) do
    assigns
    |> Map.get(:regional_rows, %{})
    |> Map.values()
    |> Enum.map(& &1.items)
  end

  @doc "Applies `fun` to every row's item list (re-enrichment after add/request)."
  def map_items(socket, fun) do
    rows =
      Map.new(socket.assigns.regional_rows, fn {param, row} ->
        {param, %{row | items: fun.(row.items)}}
      end)

    assign(socket, :regional_rows, rows)
  end

  defp put_row(socket, param, row),
    do: assign(socket, :regional_rows, Map.put(socket.assigns.regional_rows, param, row))
end
