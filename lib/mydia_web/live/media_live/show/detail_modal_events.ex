defmodule MydiaWeb.MediaLive.Show.DetailModalEvents do
  @moduledoc """
  The detail page's host side of `TrendingDetailModal` and of the person popup.

  An adapter, like `RecommendationComponents` and `FranchiseComponents`: the
  state lives in `MydiaWeb.Live.Helpers.DetailModal` and
  `MydiaWeb.Live.Helpers.PersonModal`, and this module only maps this page's
  item lists and two add handlers onto them.

  A clicked title can come from the recommendations rail, the franchise strip,
  the rail inside the dialog itself, or an open person's titles. All four are
  searched, in that order, because a title reached by hopping through the
  dialog or a person is in none of the page's own lists and resolving against
  those alone would drop the click silently.

  Every lookup passes the media type. The page's own rails share the viewed
  title's type, but a person's titles mix movies and shows, and TMDB namespaces
  ids per type, so a movie and a show can share one.

  Adds and requests are dispatched by franchise membership, the same way
  `AddConfigEvents` already routes the page's single configure dialog. Only a
  movie can be a franchise entry. An item that is in neither of the page's
  lists falls to the recommendation branch, which is correct: both paths add by
  TMDB id, and `RecommendationEvents.perform_add/5` inherits the viewed item's
  monitored flag and quality profile, the right default for anything reached
  from this page. The media type comes from the clicked item, not the viewed
  one: a show opened from an actor on a movie's page is added as a show.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Mydia.Media.Recommendations
  alias Mydia.Metadata.Ref
  alias MydiaWeb.Live.Helpers.DetailModal
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers
  alias MydiaWeb.Live.Helpers.PersonModal
  alias MydiaWeb.MediaLive.Show.AddConfigEvents
  alias MydiaWeb.MediaLive.Show.FranchiseComponents
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  require Logger

  @doc """
  Opens the dialog over the clicked title.

  An unresolvable id is dropped rather than raising: the rails re-render on
  every add, and a click that races a re-render must not take the page down.
  """
  def show_details(%{"id" => id, "type" => type}, socket) do
    media_type = media_type(type)

    case DetailModal.find_selectable_item(item_lists(socket), id, media_type) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply, DetailModal.select(socket, item, media_type)}
    end
  end

  @doc "Closes the dialog."
  def close_details(_params, socket), do: {:noreply, DetailModal.close(socket)}

  @doc """
  Opens the person popup. It replaces the title dialog; a title opened from the
  person's posters stacks over the person instead (see `show_details/2`).
  """
  def show_person(params, socket),
    do: {:noreply, socket |> DetailModal.close() |> PersonModal.open(params)}

  @doc "Closes the person popup."
  def close_person(_params, socket), do: {:noreply, PersonModal.close(socket)}

  @doc "Re-runs a failed person lookup."
  def retry_person(_params, socket), do: {:noreply, PersonModal.retry(socket)}

  @doc "Stores the person lookup result."
  def handle_person_result(result, socket),
    do: {:noreply, PersonModal.handle_result(socket, result)}

  @doc """
  Re-reads the library and request status of the open person's titles.

  Called after an add or a request: without it a poster never gains its owned
  or requested badge. A no-op while no person is loaded.
  """
  def refresh_person_titles(%{assigns: %{selected_person: %{} = person}} = socket) do
    assign(
      socket,
      :person_titles,
      PersonModal.enrich_titles(person, socket.assigns.current_scope)
    )
  end

  def refresh_person_titles(socket), do: socket

  @doc """
  Adds the title the dialog is open over, through the rail it belongs to.
  """
  def add_selected_item(%{"ref" => raw_ref} = params, socket) do
    case Ref.parse(raw_ref) do
      {:ok, ref} ->
        if franchise_click?(socket, ref, params) do
          FranchiseEvents.add_franchise_movie(params, socket)
        else
          RecommendationEvents.add_recommendation(params, socket)
        end

      :error ->
        {:noreply, socket}
    end
  end

  @doc """
  Requests the title the dialog is open over, through the rail it belongs to.
  """
  def request_selected_item(%{"ref" => raw_ref} = params, socket) do
    case Ref.parse(raw_ref) do
      {:ok, ref} ->
        if franchise_click?(socket, ref, params) do
          FranchiseEvents.request_franchise_movie(params, socket)
        else
          RecommendationEvents.request_recommendation(params, socket)
        end

      :error ->
        {:noreply, socket}
    end
  end

  @doc """
  The lists a poster click resolves against, in precedence order.

  Public so the add and request paths can reuse it when refreshing the dialog's
  own snapshot of the item. See `DetailModal.refresh_selected/2`. A person's
  titles mix media types, so every lookup against these lists passes one.
  """
  def item_lists(socket) do
    [
      socket.assigns[:recommendations] || [],
      franchise_items(socket.assigns[:franchise]),
      socket.assigns[:selected_recommendations] || [],
      socket.assigns[:person_titles] || []
    ]
  end

  @doc """
  Starts the lookup behind the dialog's own rail.

  Through `start_async/3` rather than inline: on a cache miss this is a relay
  call with the config's timeout, and the dialog is already on screen by then,
  so doing it in the handle_info would queue Close, Add and Request behind the
  fetch and the dialog would look frozen.
  """
  def fetch_recommendations(socket, ref, media_type) do
    config = socket.assigns.metadata_config
    scope = socket.assigns.current_scope

    start_async(socket, :load_selected_recommendations, fn ->
      Recommendations.for_ref(ref, media_type, scope, config)
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

  # A franchise is a TMDB movie collection, so a show sharing a member's TMDB
  # id (a person's TV credit) is never routed there.
  defp franchise_click?(socket, ref, params) do
    params["media_type"] != "tv_show" and
      AddConfigEvents.franchise_entry?(socket.assigns[:franchise], ref)
  end

  defp franchise_items(nil), do: []
  defp franchise_items(franchise), do: FranchiseComponents.rail_items(franchise)

  defp media_type("tv_show"), do: :tv_show
  defp media_type(_), do: :movie

  # Mirrors RecommendationEvents.decorate/3 but without the navigate targets:
  # the rail inside the dialog keeps every poster on the dialog, and a link out
  # would close it from under the user mid-browse.
  #
  # Typed by the title the dialog is open over, not the viewed one: a show
  # opened from an actor on a movie's page has show recommendations.
  defp decorate(socket, results) do
    type = dialog_type(socket)
    results = Enum.filter(results, &(RecommendationEvents.safe_provider_id(&1) != nil))
    tmdb_ids = Enum.map(results, &RecommendationEvents.safe_provider_id/1)

    status =
      Mydia.Media.library_status_for_tmdb_ids(socket.assigns.current_scope, tmdb_ids, type)

    results
    |> RecommendationEvents.stamp_media_type(type)
    |> MediaAddHelpers.enrich_with_library_status(status)
    |> MediaRequestHelpers.enrich_with_request_status(MediaRequestHelpers.request_status_map())
  end

  defp dialog_type(socket) do
    case socket.assigns[:selected_item] do
      %{media_type: media_type} when media_type in [:movie, :tv_show] ->
        to_string(media_type)

      _ ->
        socket.assigns.media_item.type
    end
  end
end
