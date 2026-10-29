defmodule MydiaWeb.MediaLive.Show.SearchFilterEvents do
  @moduledoc """
  The manual search dialog's filter and sort events.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Mydia.Quality.Sources

  import MydiaWeb.MediaLive.Show.SearchHelpers

  @filter_dimensions %{
    "quality" => :quality_filters,
    "source" => :source_filters,
    "codec" => :codec_filters,
    "indexer" => :indexer_filters
  }

  @sort_options %{"quality" => :quality, "seeders" => :seeders, "size" => :size, "date" => :date}

  @doc """
  Routes the manual search dialog's filter and sort events, which
  `MydiaWeb.MediaLive.Show` forwards through a single `handle_event/3` clause.
  """
  def handle_filter_event("filter_search", params, socket), do: filter_search(params, socket)
  def handle_filter_event("sort_search", params, socket), do: sort_search(params, socket)

  def handle_filter_event("remove_search_filter", params, socket),
    do: remove_search_filter(params, socket)

  def handle_filter_event("clear_search_filters", params, socket),
    do: clear_search_filters(params, socket)

  def filter_search(params, socket) do
    # A tracker already selected stays valid even after it drops out of the
    # pool, so its chip can still be cleared.
    indexers =
      socket.assigns.raw_search_results
      |> known_indexers()
      |> MapSet.union(MapSet.new(socket.assigns.indexer_filters))

    {:noreply,
     socket
     |> assign(:min_seeders, parse_min_seeders(params["min_seeders"]))
     |> assign(
       :quality_filters,
       params |> selected("quality") |> Enum.map(&normalize_quality/1) |> known(quality_options())
     )
     |> assign(:source_filters, params |> selected("source") |> known(Sources.all()))
     |> assign(:codec_filters, params |> selected("codec") |> known(codec_families()))
     |> assign(:indexer_filters, params |> selected("indexer") |> known(indexers))
     |> apply_search_filters()}
  end

  def remove_search_filter(%{"dimension" => "min_seeders"}, socket),
    do: {:noreply, socket |> assign(:min_seeders, 0) |> apply_search_filters()}

  def remove_search_filter(%{"dimension" => dimension}, socket)
      when is_map_key(@filter_dimensions, dimension) do
    {:noreply,
     socket |> assign(Map.fetch!(@filter_dimensions, dimension), []) |> apply_search_filters()}
  end

  def remove_search_filter(_params, socket), do: {:noreply, socket}

  def clear_search_filters(_params, socket) do
    {:noreply,
     socket
     |> assign(quality_filters: [], source_filters: [], codec_filters: [], indexer_filters: [])
     |> assign(:min_seeders, 0)
     |> apply_search_filters()}
  end

  # Form params arrive as lists for checkbox groups; anything else (a forged
  # string, a nested map) is treated as no selection.
  defp selected(params, key) do
    case Map.get(params, key) do
      values when is_list(values) ->
        values |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

      _ ->
        []
    end
  end

  # Values outside the known vocabulary (or the pool, for indexers) are dropped,
  # which also keeps a forged param out of the assigns.
  defp known(values, known), do: Enum.filter(values, &Enum.member?(known, &1))

  defp parse_min_seeders(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_min_seeders(_value), do: 0

  def sort_search(%{"sort_by" => sort_by}, socket) when is_map_key(@sort_options, sort_by) do
    {:noreply,
     socket
     |> assign(:sort_by, Map.fetch!(@sort_options, sort_by))
     |> apply_search_sort()}
  end

  def sort_search(_params, socket), do: {:noreply, socket}
end
