defmodule MydiaWeb.MediaLive.Show.DetailModalEvents do
  @moduledoc """
  The detail page's host side of `TrendingDetailModal`.

  An adapter, like `RecommendationComponents` and `FranchiseComponents`: the
  state lives in `MydiaWeb.Live.Helpers.DetailModal`, and this module only maps
  this page's three item lists and two add handlers onto it.

  A clicked title can come from the recommendations rail, the franchise strip,
  or the rail inside the dialog itself. All three are searched, in that order,
  because a title reached by hopping through the dialog is in none of the page's
  own lists and resolving against those alone would drop the click silently.

  Adds and requests are dispatched by franchise membership, the same way
  `LibraryPickerEvents` already routes the page's single library picker. An item
  that is in neither of the page's lists falls to the recommendation branch,
  which is correct: both paths add by TMDB id, and
  `RecommendationEvents.perform_add/4` inherits the viewed item's monitored flag
  and quality profile, the right default for anything reached from this page.
  """

  import Phoenix.LiveView, only: [start_async: 3]

  alias Mydia.Media.Recommendations
  alias MydiaWeb.Live.Helpers.DetailModal
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers
  alias MydiaWeb.MediaLive.Show.FranchiseComponents
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.LibraryPickerEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  require Logger

  @doc """
  Opens the dialog over the clicked title.

  An unresolvable id is dropped rather than raising: the rails re-render on
  every add, and a click that races a re-render must not take the page down.
  """
  def show_details(%{"id" => id, "type" => type}, socket) do
    case find_item(socket, id) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply, DetailModal.select(socket, item, media_type(type))}
    end
  end

  @doc "Closes the dialog."
  def close_details(_params, socket), do: {:noreply, DetailModal.close(socket)}

  @doc """
  Adds the title the dialog is open over, through the rail it belongs to.
  """
  def add_selected_item(%{"tmdb_id" => tmdb_id} = params, socket) do
    if LibraryPickerEvents.franchise_entry?(socket.assigns[:franchise], tmdb_id) do
      FranchiseEvents.add_franchise_movie(params, socket)
    else
      RecommendationEvents.add_recommendation(params, socket)
    end
  end

  @doc """
  Requests the title the dialog is open over, through the rail it belongs to.
  """
  def request_selected_item(%{"tmdb_id" => tmdb_id} = params, socket) do
    if LibraryPickerEvents.franchise_entry?(socket.assigns[:franchise], tmdb_id) do
      FranchiseEvents.request_franchise_movie(params, socket)
    else
      RecommendationEvents.request_recommendation(params, socket)
    end
  end

  @doc """
  The lists a poster click resolves against, in precedence order.

  Public so the add and request paths can reuse it when refreshing the dialog's
  own snapshot of the item. See `DetailModal.refresh_selected/2`.
  """
  def item_lists(socket) do
    [
      socket.assigns[:recommendations] || [],
      franchise_items(socket.assigns[:franchise]),
      socket.assigns[:selected_recommendations] || []
    ]
  end

  @doc """
  Starts the lookup behind the dialog's own rail.

  Through `start_async/3` rather than inline: on a cache miss this is a relay
  call with the config's timeout, and the dialog is already on screen by then,
  so doing it in the handle_info would queue Close, Add and Request behind the
  fetch and the dialog would look frozen.
  """
  def fetch_recommendations(socket, tmdb_id, media_type) do
    config = socket.assigns.metadata_config

    start_async(socket, :load_selected_recommendations, fn ->
      Recommendations.for_tmdb_id(tmdb_id, media_type, config)
    end)
  end

  @doc """
  Stores the dialog's rail, or leaves it empty on anything but a clean result.

  An empty rail renders nothing at all, which is the designed behaviour for a
  title TMDB has no recommendations for. A crash must not take the page down for
  a section that is meant to be silently absent.
  """
  def handle_recommendations_result({:ok, {:ok, results}}, socket) do
    {:noreply, DetailModal.put_recommendations(socket, results, &decorate(socket, &1))}
  end

  def handle_recommendations_result({:ok, :none}, socket) do
    {:noreply, DetailModal.put_recommendations(socket, [], & &1)}
  end

  def handle_recommendations_result({:exit, reason}, socket) do
    Logger.warning("Detail dialog recommendations lookup crashed: #{inspect(reason)}")
    {:noreply, DetailModal.put_recommendations(socket, [], & &1)}
  end

  def handle_recommendations_result(other, socket) do
    Logger.warning(
      "Detail dialog recommendations returned an unexpected result: #{inspect(other)}"
    )

    {:noreply, DetailModal.put_recommendations(socket, [], & &1)}
  end

  defp find_item(socket, id), do: DetailModal.find_selectable_item(item_lists(socket), id)

  defp franchise_items(nil), do: []
  defp franchise_items(franchise), do: FranchiseComponents.rail_items(franchise)

  defp media_type("tv_show"), do: :tv_show
  defp media_type(_), do: :movie

  # Mirrors RecommendationEvents.decorate/3 but without the navigate targets:
  # the rail inside the dialog keeps every poster on the dialog, and a link out
  # would close it from under the user mid-browse.
  defp decorate(socket, results) do
    media_item = socket.assigns.media_item
    results = Enum.filter(results, &(RecommendationEvents.safe_provider_id(&1) != nil))
    tmdb_ids = Enum.map(results, &RecommendationEvents.safe_provider_id/1)

    status = Mydia.Media.library_status_for_tmdb_ids(tmdb_ids, media_item.type)

    results
    |> MediaAddHelpers.enrich_with_library_status(status)
    |> MediaRequestHelpers.enrich_with_request_status(MediaRequestHelpers.request_status_map())
  end
end
