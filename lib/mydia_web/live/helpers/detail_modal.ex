defmodule MydiaWeb.Live.Helpers.DetailModal do
  @moduledoc """
  Host-side state for `MydiaWeb.Live.Components.TrendingDetailModal`.

  Discover, the Dashboard and the media detail page all open the same dialog
  over the same four assigns. Before this module the first two each declared
  those assigns, the select/close pair and the metadata fetch by hand, and the
  detail page would have been a third copy of the same eighty lines.

  Assigns owned here:

    * `:selected_item` - the enriched `SearchResult` the dialog is open over,
      or nil when it is closed
    * `:selected_metadata` - the fuller `MediaMetadata`, once fetched
    * `:detail_loading` - whether that fetch is in flight
    * `:selected_recommendations` - the rail rendered inside the dialog

  Both lookups are messages to `self()` rather than direct calls, so the dialog
  paints its loading state before any relay round trip starts. The host owns the
  `handle_info` clauses and hands their results back through `put_metadata/2`
  and `put_recommendations/3`.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns every dialog assign to its empty value. Call from `mount/3`.
  """
  def init(socket) do
    socket
    |> assign(:selected_item, nil)
    |> assign(:selected_metadata, nil)
    |> assign(:detail_loading, false)
    |> assign(:selected_recommendations, [])
  end

  @doc """
  Opens the dialog over `item` and starts both lookups.

  The rail is cleared rather than left in place: without that, the previous
  title's recommendations stay on screen under the new header until the fetch
  lands, which reads as the dialog having opened over the wrong item.

  `recommendations: false` skips the rail lookup entirely, which is what a host
  that renders no `:rail` slot wants. The fetch would otherwise pay for a relay
  round trip whose result nothing renders.
  """
  def select(socket, item, media_type, opts \\ []) do
    id = to_string(item.provider_id)

    send(self(), {:fetch_detail_metadata, id, media_type})

    if Keyword.get(opts, :recommendations, true) do
      send(self(), {:fetch_recommendations, id, media_type})
    end

    socket
    |> assign(:selected_item, item)
    |> assign(:selected_metadata, nil)
    |> assign(:selected_recommendations, [])
    |> assign(:detail_loading, true)
  end

  @doc """
  Closes the dialog.

  `:selected_recommendations` is deliberately left alone. It is not rendered
  with the dialog shut, and `select/4` clears it on the way back in.
  """
  def close(socket) do
    socket
    |> assign(:selected_item, nil)
    |> assign(:selected_metadata, nil)
    |> assign(:detail_loading, false)
  end

  @doc """
  Stores the metadata lookup result and clears the loading flag.

  A failed lookup still clears the flag: the dialog falls back to the
  `SearchResult` it was opened with, which carries title, year, poster and
  rating. No trailer and no synopsis, but no spinner forever either.
  """
  def put_metadata(socket, {:ok, metadata}) do
    socket
    |> assign(:selected_metadata, metadata)
    |> assign(:detail_loading, false)
  end

  def put_metadata(socket, {:error, _reason}) do
    assign(socket, :detail_loading, false)
  end

  @doc """
  Stores the in-dialog rail, after the host's own enrichment.

  The enrichment is a function rather than a fixed step because the hosts
  disagree about where library and request status come from: Discover holds
  cached status maps in its assigns, while the media detail page queries per
  lookup.
  """
  def put_recommendations(socket, results, enrich) when is_function(enrich, 1) do
    assign(socket, :selected_recommendations, enrich.(results))
  end

  @doc """
  Resolves a provider id against several lists, first match wins.

  A clicked title may live in the grid, in the page's own rail, or only in the
  rail inside the dialog. Resolving against one list alone drops the click and
  the dialog never swaps, a failure that looks like nothing happening.

  Ids are compared as strings on both sides: a `SearchResult`'s `provider_id`
  is a string while several hosts hold parsed integers.

  `media_type` is optional and defaults to nil, which matches on id alone as
  before. Click resolution leaves it out: every list a click resolves against
  is homogeneous by media type already (Discover's grid and rail are both
  movies or both TV shows for the active tab; the detail page's rails all
  belong to the viewed title's type), so the id alone is unambiguous there.
  `refresh_selected/2`, below, is the one caller that passes it, because TMDB
  namespaces ids per media type and its lists are not homogeneous.
  """
  def find_selectable_item(lists, id, media_type \\ nil) do
    id = to_string(id)

    Enum.find_value(lists, fn list ->
      Enum.find(list, &matches_selectable?(&1, id, media_type))
    end)
  end

  defp matches_selectable?(item, id, nil), do: to_string(item.provider_id) == id

  defp matches_selectable?(item, id, media_type) do
    to_string(item.provider_id) == id and Map.get(item, :media_type) == media_type
  end

  @doc """
  Re-resolves `:selected_item` from `lists` after an add or a request.

  The dialog reads a snapshot taken when it opened. Adding from inside it
  updates the card underneath but not that snapshot, so without this the header
  keeps offering "Add to Library" for a title that is now in the library, and a
  second click fails on the tmdb_id index.

  An id that is in none of the lists leaves the selection untouched rather than
  clearing it: the dialog is still open, and blanking it would close it out from
  under the user.

  The stale item's `media_type` is passed to `find_selectable_item/3` alongside
  its id. The Dashboard is the one caller whose lists mix media types
  (`[trending_movies, trending_tv]`), and TMDB namespaces ids per type, so a
  movie and a show can share one. Without the type check a refresh could swap
  the dialog onto a same-id title of the other kind instead of just refreshing
  the one already open. Every other caller's lists are homogeneous, so this is
  a no-op there.
  """
  def refresh_selected(socket, lists) do
    case socket.assigns.selected_item do
      nil ->
        socket

      item ->
        case find_selectable_item(lists, item.provider_id, Map.get(item, :media_type)) do
          nil -> socket
          fresh -> assign(socket, :selected_item, fresh)
        end
    end
  end
end
