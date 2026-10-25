defmodule MydiaWeb.MediaLive.Index.Window do
  @moduledoc """
  The part of a listing snapshot on screen: `listing_ids` from `window_start`
  up to, not including, `window_end`.

  A fresh listing starts at the top, or at the URL's A-Z `letter`. Scrolling
  down extends `window_end` a batch at a time; after a jump, scrolling up
  extends `window_start` back towards the top. `letter_start` keeps where the
  letter put it.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, stream: 3, stream: 4]

  alias Mydia.Media.LibraryListing
  alias MydiaWeb.MediaLive.Index.ListingParams

  @items_per_scroll 50

  # A multiple of 12, so a prepended batch fills whole rows in a 2, 3, 4 or
  # 6 column grid and the cards already on screen do not shift sideways.
  @previous_batch 48

  @doc "Assigns for a listing with nothing loaded, and an empty stream."
  def reset(socket) do
    socket
    |> assign(:listing_ids, [])
    |> assign(:window_start, 0)
    |> assign(:letter_start, 0)
    |> assign(:window_end, 0)
    |> assign(:has_more, false)
    |> assign(:has_previous, false)
    |> assign(:letter_offsets, %{})
    |> assign(:letter_paths, %{})
    |> stream(:media_items, [], reset: true)
  end

  # The HTTP render paints a skeleton and loads nothing. The connected mount
  # runs handle_params again moments later, so loading here doubled the cost
  # of every full page load.
  def load_media_items_when_connected(socket, limit) do
    if connected?(socket), do: load_media_items(socket, limit), else: socket
  end

  # A fresh snapshot. Without a limit it keeps as many rows as are on screen
  # below the letter, so a reload after a bulk action does not throw the user
  # back to the top. Rows loaded above the letter are dropped.
  def load_media_items(socket, limit \\ nil)

  def load_media_items(%{assigns: %{section_error: true}} = socket, _limit), do: socket

  def load_media_items(socket, limit) do
    limit = limit || max(rows_from_letter(socket.assigns), ListingParams.first_page())

    snapshot =
      LibraryListing.snapshot(
        socket.assigns.current_scope,
        listing_opts(socket.assigns, limit: limit, letter: socket.assigns.letter)
      )

    stop = snapshot.start + length(snapshot.rows)

    socket
    |> assign(:listing_ids, snapshot.ids)
    |> assign(:window_start, snapshot.start)
    |> assign(:letter_start, snapshot.start)
    |> assign(:window_end, stop)
    |> assign(:has_more, stop < length(snapshot.ids))
    |> assign(:has_previous, snapshot.start > 0)
    |> assign(:letter_offsets, snapshot.letter_offsets)
    |> assign(:letter_paths, letter_paths(socket.assigns, snapshot.letter_offsets))
    |> assign(:loading?, false)
    |> assign(:media_items_empty?, snapshot.empty?)
    # Every matching id, not only the rendered rows, for "Select All".
    |> assign(:all_visible_ids, snapshot.visible_ids)
    |> assign(:total_size, snapshot.total_size)
    |> assign(:description_match_start_id, snapshot.description_match_start_id)
    |> stream(:media_items, snapshot.rows, reset: true)
  end

  # The next batch, from the snapshot's order. Advances by ids, not by rows
  # returned, so an item deleted since the snapshot is skipped, not retried.
  # The window counts ids consumed, not cards rendered, so `shown` can
  # slightly overstate the cards on screen after a deletion; that is harmless.
  def load_next_batch(socket) do
    %{listing_ids: ids, window_end: stop} = socket.assigns
    batch = Enum.slice(ids, stop, @items_per_scroll)
    stop = stop + length(batch)

    socket
    |> assign(:window_end, stop)
    |> assign(:has_more, stop < length(ids))
    |> stream(:media_items, rows(socket, batch))
  end

  # The batch above the window after a jump. The stream inserts each row at 0
  # in turn, so they are reversed to land in order.
  def load_previous_batch(socket) do
    %{listing_ids: ids, window_start: start} = socket.assigns
    from = max(start - @previous_batch, 0)
    batch = Enum.slice(ids, from, start - from)

    socket
    |> assign(:window_start, from)
    |> assign(:has_previous, from > 0)
    |> stream(:media_items, socket |> rows(batch) |> Enum.reverse(), at: 0)
  end

  @doc "The URL state for what is on screen now."
  def listing_params(assigns) do
    %ListingParams{
      search: assigns.search_query,
      library: assigns.filter_library,
      progress: assigns.filter_progress,
      monitored: assigns.filter_monitored,
      quality: assigns.filter_quality,
      sort: assigns.sort_by,
      letter: assigns.letter,
      shown:
        min(
          max(rows_from_letter(assigns), ListingParams.first_page()),
          ListingParams.max_shown()
        )
    }
  end

  # The A-Z strip's links, built once per snapshot so the strip re-renders only
  # when the listing changes. A jump keeps the filters and sort and starts a
  # fresh first batch at the letter.
  defp letter_paths(assigns, letter_offsets) do
    params = %{listing_params(assigns) | shown: ListingParams.first_page()}

    Map.new(letter_offsets, fn {letter, _offset} ->
      {letter, ListingParams.path(assigns.listing_base_path, %{params | letter: letter})}
    end)
  end

  # `shown` and reloads count from where the letter started the window, so
  # rows loaded above it neither inflate the URL nor survive a reload.
  defp rows_from_letter(assigns), do: assigns.window_end - assigns.letter_start

  defp rows(socket, ids),
    do: LibraryListing.rows(socket.assigns.current_scope, ids, socket.assigns.current_user.id)

  defp listing_opts(assigns, page_opts) do
    []
    |> maybe_add_filter(:base_query, assigns[:section_query])
    # A section's own base_query already selects its claimed categories, so
    # excluding those same categories here would contradict it and empty the
    # section out. The exclusion only makes sense off of section pages, where
    # it is what removes claimed items from the built-in Movies/TV listings.
    |> maybe_add_filter(
      :exclude_categories,
      if(is_nil(assigns[:section]), do: assigns[:excluded_categories], else: [])
    )
    |> maybe_add_filter(:type, assigns.filter_type)
    |> maybe_add_filter(:monitored, assigns.filter_monitored)
    |> maybe_add_filter(:library_path_id, assigns[:filter_library])
    |> Keyword.merge(
      user_id: assigns.current_user.id,
      search: assigns.search_query,
      quality: assigns.filter_quality,
      progress: assigns.filter_progress,
      sort_by: assigns.sort_by
    )
    |> Keyword.merge(page_opts)
  end

  defp maybe_add_filter(opts, _key, []), do: opts
  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)
end
