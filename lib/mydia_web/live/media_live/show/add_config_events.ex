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

  The preamble every host of the dialog shares, authorization included, lives
  in `MediaAddHelpers.resolve_add_config_submit/2`. It closes the dialog before
  returning opts: leaving it open while an async add runs would let a second
  submit queue behind the first.

  Only the dispatch below is local, because this page is the one host with two
  rails to choose between.
  """
  def submit_add_config(%{"config" => params}, socket) do
    case MediaAddHelpers.resolve_add_config_submit(socket, params) do
      {:ok, tmdb_id, _media_type, opts, socket} -> dispatch(tmdb_id, opts, socket)
      {:halt, socket} -> {:noreply, socket}
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
