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

  alias MydiaWeb.Live.Helpers.DetailModal
  alias MydiaWeb.MediaLive.Show.FranchiseComponents
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.LibraryPickerEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  @doc """
  Opens the dialog over the clicked title.

  An unresolvable id is dropped rather than raising: the rails re-render on
  every add, and a click that races a re-render must not take the page down.

  This task ships the dialog without an in-dialog rail, which is a complete,
  shippable state: it is exactly what the Dashboard renders permanently. So
  `recommendations: false` is passed for the same reason the Dashboard passes
  it: with no `:rail` slot on this page yet, the lookup would pay for a relay
  round trip nothing draws.
  """
  def show_details(%{"id" => id, "type" => type}, socket) do
    case find_item(socket, id) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply, DetailModal.select(socket, item, media_type(type), recommendations: false)}
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

  defp find_item(socket, id), do: DetailModal.find_selectable_item(item_lists(socket), id)

  defp franchise_items(nil), do: []
  defp franchise_items(franchise), do: FranchiseComponents.rail_items(franchise)

  defp media_type("tv_show"), do: :tv_show
  defp media_type(_), do: :movie
end
