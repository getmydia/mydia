defmodule MydiaWeb.MediaLive.Index.RememberedListing do
  @moduledoc """
  Saves a library page's sort and filters per user and restores them on the
  next visit. The page is keyed by the socket's `page_key`; the last saved
  pairs live in the `:remembered_listing` assign.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  require Logger

  alias Mydia.Accounts.LibraryListingState
  alias MydiaWeb.MediaLive.Index.ListingParams
  alias MydiaWeb.MediaLive.Index.Window

  # The key a page's sort and filters are saved under.
  defp page(%{assigns: %{page_key: {:movies, _id}}}), do: "movies"
  defp page(%{assigns: %{page_key: {:tv_shows, _id}}}), do: "tv_shows"
  defp page(%{assigns: %{page_key: {:section, id}}}), do: "section:" <> id

  @doc """
  Entering a page whose URL sets no sort or filter starts from the ones the
  user last chose there. The saved pairs go through the same parse as the
  URL, so a deleted library or a retired sort key falls back to its default.
  Returns the merged params and, when it restored anything, the path the URL
  is patched to once they are applied (`patch_restored/2`); that patch then
  sees the same listing and reloads nothing. Patching before applying would
  mark the socket redirected and skip the load. A URL that sets any of them
  wins outright. `library_ids` are the libraries the page offers.
  """
  def restore(%{redirected: redirected} = socket, params, _library_ids)
      when not is_nil(redirected),
      do: {socket, params, nil}

  def restore(socket, params, library_ids) do
    saved = LibraryListingState.get(socket.assigns.current_user, page(socket))
    socket = assign(socket, :remembered_listing, saved)

    if saved == %{} or ListingParams.listing_in_url?(params) do
      {socket, params, nil}
    else
      params = Map.merge(saved, params)
      restored = ListingParams.parse(params, library_ids)
      {socket, params, ListingParams.path(socket.assigns.listing_base_path, restored)}
    end
  end

  def patch_restored(socket, nil), do: socket

  def patch_restored(%{redirected: redirected} = socket, _path) when not is_nil(redirected),
    do: socket

  def patch_restored(socket, path) do
    if connected?(socket), do: push_patch(socket, to: path, replace: true), else: socket
  end

  @doc """
  Saves the page's sort and filters when the change alters the listing on
  screen, so a search, or a URL that overrides the saved state, writes
  nothing until the user picks a sort or filter. Clear filters (`forget?`)
  also drops a saved state the screen was not showing. A failed write only
  costs the memory of this choice, so it never blocks the patch.
  """
  def remember(socket, %ListingParams{} = params, forget?) do
    pairs = ListingParams.to_remembered(params)
    shown = ListingParams.to_remembered(Window.listing_params(socket.assigns))

    if pairs == socket.assigns.remembered_listing or (pairs == shown and not forget?) do
      socket
    else
      case LibraryListingState.put(socket.assigns.current_user, page(socket), pairs) do
        :ok ->
          assign(socket, :remembered_listing, pairs)

        {:error, reason} ->
          Logger.warning("Could not save library listing state: #{inspect(reason)}")
          socket
      end
    end
  end
end
