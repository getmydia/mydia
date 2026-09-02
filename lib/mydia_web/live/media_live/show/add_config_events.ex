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
  alias Mydia.Metadata.Ref
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
      {:ok, ref, _media_type, opts, socket} -> dispatch(ref, opts, socket)
      {:halt, socket} -> {:noreply, socket}
    end
  end

  defp dispatch(ref, opts, socket) do
    if franchise_entry?(socket.assigns[:franchise], ref) do
      FranchiseEvents.add_franchise_movie_with_opts(ref, opts, socket)
    else
      RecommendationEvents.add_recommendation_with_opts(ref, opts, socket)
    end
  end

  @doc """
  Whether `ref` belongs to the franchise strip rather than the
  recommendations rail.

  Public because the detail dialog routes its own add and request the same way.
  When the same movie sits in both rails (#460) the franchise strip wins and the
  recommendations card stays stale; a later click there resolves to
  `:already_in_library`, which both perform_add functions map to an
  informational result rather than an error.

  A franchise is always a TMDB collection (see `FranchiseEntry`, which only
  ever carries `tmdb_id`), so a `{:tvdb, _}` ref can never be a franchise
  member -- `Ref.parse/1` accepting `tvdb:<id>` does not change that. Checked
  on the ref's tag before its bare id: matching a TVDB numeric id against
  `entry.tmdb_id` alone would route a forged or genuinely TVDB-sourced (a TV
  show's recommendation card) ref into the franchise/movie-only add and
  request paths whenever the two catalogs' ids happen to collide.
  """
  def franchise_entry?(franchise, ref)

  def franchise_entry?(_franchise, {:tvdb, _id}), do: false
  def franchise_entry?(nil, _ref), do: false

  def franchise_entry?(%{entries: entries}, ref) do
    id = Ref.id(ref)

    Enum.any?(entries, fn %FranchiseEntry{} = entry ->
      to_string(entry.tmdb_id) == to_string(id)
    end)
  end

  def franchise_entry?(_franchise, _ref), do: false
end
