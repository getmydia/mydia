defmodule MydiaWeb.MediaLive.Show.AddConfigEvents do
  @moduledoc """
  Routes the detail page's single configure dialog to the right rail.

  The dialog is page-level and fires one event per host, but this page has two
  rails with different add handlers. Rather than teach the shared dialog about
  sources, the event lands here and is dispatched by franchise membership.

  When the same movie sits in both rails (#460) the franchise strip wins and the
  recommendations card stays stale. A later click on that stale card resolves to
  `:already_in_library`, which both `perform_add` functions map to an
  informational result rather than an error.

  Replaces `LibraryPickerEvents`, which did the same dispatch for the deleted
  "Add to which library?" dialog.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media.FranchiseEntry
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  @doc """
  Opens the configure dialog for one card in either rail.

  The franchise strip may not have loaded yet, so its entries default to an
  empty list rather than being read off a nil struct.
  """
  def open_add_config(params, socket) do
    franchise_entries =
      case socket.assigns[:franchise] do
        %{entries: entries} -> entries
        _ -> []
      end

    {:noreply,
     MediaAddHelpers.put_add_config(
       socket,
       params,
       socket.assigns.current_user,
       [franchise_entries, socket.assigns[:recommendations] || []]
     )}
  end

  @doc """
  Closes the configure dialog.
  """
  def close_add_config(_params, socket) do
    {:noreply, MediaAddHelpers.clear_add_config(socket)}
  end

  @doc """
  Dispatches a configured add to the rail the card belongs to.

  The dialog is closed first, unconditionally: leaving it open while an async
  add runs would let a second submit queue behind the first.
  """
  def submit_add_config(%{"config" => params}, socket) do
    case socket.assigns[:add_config] do
      nil ->
        {:noreply, socket}

      %{provider_id: tmdb_id, media_type: media_type} ->
        socket = MediaAddHelpers.clear_add_config(socket)

        case MediaAddHelpers.add_opts_from_config(params, media_type, socket.assigns.current_user) do
          {:ok, opts} ->
            dispatch(tmdb_id, opts, socket)

          {:error, :unknown_library} ->
            {:noreply,
             put_flash(socket, :error, "That library is no longer available. Nothing was added.")}
        end
    end
  end

  defp dispatch(tmdb_id, opts, socket) do
    if franchise_entry?(socket.assigns[:franchise], tmdb_id) do
      FranchiseEvents.add_franchise_movie_with_opts(to_string(tmdb_id), opts, socket)
    else
      RecommendationEvents.add_recommendation_with_opts(to_string(tmdb_id), opts, socket)
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
