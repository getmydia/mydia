defmodule MydiaWeb.MediaLive.Show.LibraryPickerEvents do
  @moduledoc """
  Routes the detail page's single library-picker dialog to the right rail.

  `library_picker_dialog/1` is page-level and fires one event per host, but
  this page has two rails with different add handlers. Rather than teach the
  shared dialog about sources, the event lands here and is dispatched by
  franchise membership.

  When the same movie sits in both rails (#460) the franchise strip wins and
  the recommendations card stays stale. A later click on that stale card
  resolves to `:already_in_library`, which both `perform_add` functions map to
  an informational result rather than an error.
  """

  alias Mydia.Media.FranchiseEntry
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  @doc """
  Opens the picker for one card.
  """
  def open_library_picker(params, socket) do
    {:noreply, MediaAddHelpers.put_library_picker(socket, params)}
  end

  @doc """
  Closes the picker.
  """
  def close_library_picker(_params, socket) do
    {:noreply, MediaAddHelpers.clear_library_picker(socket)}
  end

  @doc """
  Dispatches a chosen library to the rail the card belongs to.

  The dialog is closed first, unconditionally: leaving it open while an async
  add runs would let a second choice queue behind the first.
  """
  def add_from_library_picker(%{"tmdb_id" => tmdb_id} = params, socket) do
    socket = MediaAddHelpers.clear_library_picker(socket)

    if franchise_entry?(socket.assigns[:franchise], tmdb_id) do
      FranchiseEvents.add_franchise_movie(params, socket)
    else
      RecommendationEvents.add_recommendation(params, socket)
    end
  end

  defp franchise_entry?(nil, _tmdb_id), do: false

  defp franchise_entry?(%{entries: entries}, tmdb_id) do
    Enum.any?(entries, fn %FranchiseEntry{} = entry ->
      to_string(entry.tmdb_id) == to_string(tmdb_id)
    end)
  end

  defp franchise_entry?(_franchise, _tmdb_id), do: false
end
