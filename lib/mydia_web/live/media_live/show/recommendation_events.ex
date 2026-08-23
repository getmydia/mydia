defmodule MydiaWeb.MediaLive.Show.RecommendationEvents do
  @moduledoc false

  use MydiaWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, put_flash: 3, connected?: 1]

  alias Mydia.Accounts.Authorization, as: AccountsAuthorization
  alias Mydia.Media
  alias Mydia.Media.Add
  alias Mydia.Media.Recommendations
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  require Logger

  @doc """
  Starts the recommendations lookup on the connected mount.

  A no-op on the dead render, which must not pay for an HTTP call, and for
  anything that is not a movie or show with a TMDB id.
  """
  def maybe_load(socket) do
    media_item = socket.assigns.media_item
    config = socket.assigns.metadata_config

    if connected?(socket) && media_item.type in ["movie", "tv_show"] &&
         is_integer(media_item.tmdb_id) do
      start_async(socket, :load_recommendations, fn ->
        Recommendations.for_media_item(media_item, config)
      end)
    else
      socket
    end
  end

  def handle_load_result({:ok, {:ok, results}}, socket) do
    recommendations =
      decorate(results, socket.assigns.media_item, socket.assigns.current_user)

    {:noreply, assign(socket, :recommendations, recommendations)}
  end

  def handle_load_result({:ok, :none}, socket) do
    {:noreply, socket}
  end

  def handle_load_result({:exit, reason}, socket) do
    Logger.warning("Recommendations lookup crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Defensive, for the same reason as the franchise strip: an unmatched shape
  # would raise in the LiveView process, the client would reconnect, re-mount and
  # crash again, taking the whole detail page down for a section that is meant to
  # be silently absent when the lookup does not work out.
  def handle_load_result(other, socket) do
    Logger.warning("Recommendations lookup returned an unexpected result: #{inspect(other)}")
    {:noreply, socket}
  end

  @doc """
  Flips the rail open or closed.

  The rail opens collapsed on TV shows so the episode list is not pushed below a
  strip of other titles. State is per mount and deliberately not persisted, so
  every visit starts closed.
  """
  def toggle_expanded(_params, socket) do
    {:noreply,
     assign(socket, :recommendations_expanded, !socket.assigns.recommendations_expanded)}
  end

  @doc """
  Adds a recommended title, inheriting the viewed item's quality profile and
  monitored flag.

  Keyed per TMDB id so several can be in flight at once: `start_async/3`
  overwrites rather than cancels under an existing key, which would silently drop
  the first result.
  """
  def add_recommendation(%{"tmdb_id" => tmdb_id} = params, socket) do
    media_type = if socket.assigns.media_item.type == "tv_show", do: :tv_show, else: :movie

    with :ok <- Authorization.authorize_create_media(socket),
         {:ok, opts} <- MediaAddHelpers.library_path_opts(params["library_path_id"], media_type) do
      case Integer.parse(tmdb_id) do
        {parsed, ""} -> dispatch_add(parsed, opts, socket)
        _ -> {:noreply, socket}
      end
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      {:error, :unknown_library} ->
        {:noreply,
         put_flash(socket, :error, "That library is no longer available. Nothing was added.")}
    end
  end

  # An impatient double-click sends the event twice. The second add would hit the
  # tmdb_id unique index and flash a failure for a row the first add just
  # created, so a repeat for an id already in flight is dropped.
  #
  # The in-flight set stays keyed on tmdb_id alone and `opts` rides beside it.
  # Folding the library into the key would let a double-click through two
  # different libraries past this guard and onto the unique index.
  defp dispatch_add(tmdb_id, opts, socket) do
    if MapSet.member?(socket.assigns.adding_recommendation_tmdb_ids, tmdb_id) do
      {:noreply, socket}
    else
      media_item = socket.assigns.media_item
      config = socket.assigns.metadata_config

      socket =
        socket
        |> mark_in_flight(tmdb_id)
        |> start_async({:add_recommendation, tmdb_id}, fn ->
          perform_add(media_item, tmdb_id, config, opts)
        end)

      {:noreply, socket}
    end
  end

  @doc """
  Requests a recommended title on behalf of a guest.

  The rail renders a Request button rather than Add for guests, so this LiveView
  needs its own handler for it: the card's event reaches `MediaLive.Show`, which
  otherwise has no `request_media` clause at all.
  """
  def request_recommendation(%{"tmdb_id" => tmdb_id}, socket) do
    with :ok <- Authorization.authorize_submit_request(socket) do
      case Enum.find(socket.assigns.recommendations, &(to_string(&1.provider_id) == tmdb_id)) do
        nil -> {:noreply, socket}
        item -> submit_request(item, tmdb_id, socket)
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp submit_request(item, tmdb_id, socket) do
    media_type = if socket.assigns.media_item.type == "tv_show", do: :tv_show, else: :movie

    socket = assign(socket, :requesting_recommendation_id, tmdb_id)

    case MediaRequestHelpers.handle_request_media(
           item,
           media_type,
           socket.assigns.current_user.id
         ) do
      {:ok, request, status_updates} ->
        {:noreply,
         socket
         |> assign(:requesting_recommendation_id, nil)
         |> assign(
           :recommendations,
           MediaRequestHelpers.enrich_with_request_status(
             socket.assigns.recommendations,
             status_updates
           )
         )
         |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")}

      {:error, reason} ->
        Logger.warning("Recommendation request failed for tmdb #{tmdb_id}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:requesting_recommendation_id, nil)
         |> put_flash(:error, "Could not request that title")}
    end
  end

  @doc """
  Performs the add. Public so it can be exercised directly in tests without a
  live process.
  """
  def perform_add(media_item, tmdb_id, config, opts \\ []) do
    media_type = if media_item.type == "tv_show", do: :tv_show, else: :movie

    MediaAddHelpers.handle_add_media_to_library(
      to_string(tmdb_id),
      media_type,
      %{},
      config,
      Keyword.merge(
        [monitored: media_item.monitored, quality_profile_id: media_item.quality_profile_id],
        opts
      )
    )
    |> case do
      {:ok, added, _status_map} -> {:ok, added}
      # Reachable when the same title sits in both rails (#460): adding from
      # one leaves the other's card stale, and a click there lands here. Without
      # this clause it raises CaseClauseError and takes the page down.
      {:already_in_library, added, _status_map} -> {:already_in_library, added}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_add_result(tmdb_id, {:ok, {:ok, added}}, socket) do
    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> assign(:recommendations, mark_owned(socket.assigns.recommendations, added))
     |> put_flash(:info, "Added #{added.title} to your library")}
  end

  # Not an error from here up: the title the user clicked is already in the
  # library, just under a card this rail had not linked up yet.
  def handle_add_result(tmdb_id, {:ok, {:already_in_library, added}}, socket) do
    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> assign(:recommendations, mark_owned(socket.assigns.recommendations, added))
     |> put_flash(:info, "#{added.title} is already in your library")}
  end

  def handle_add_result(tmdb_id, {:ok, {:error, reason}}, socket) do
    Logger.warning("Recommendation add failed for tmdb #{tmdb_id}: #{inspect(reason)}")

    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> put_flash(:error, "Could not add that title: #{describe(reason)}")}
  end

  def handle_add_result(tmdb_id, {:exit, reason}, socket) do
    Logger.warning("Recommendation add crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> put_flash(:error, "Could not add that title")}
  end

  ## Private

  # The library join lives here rather than in Mydia.Media.Recommendations
  # because it needs MediaAddHelpers, and a context under Mydia.* must not depend
  # on the web layer.
  defp decorate(results, media_item, current_user) do
    # Drop malformed entries from the list itself, not just from the id lookup.
    # enrich_with_library_status/2 calls the same raising parser, so filtering
    # only the ids would still let a non-numeric provider_id raise one line
    # later, inside handle_load_result/2, taking the detail page down.
    results = Enum.filter(results, &(safe_provider_id(&1) != nil))
    tmdb_ids = Enum.map(results, &safe_provider_id/1)

    status = Media.library_status_for_tmdb_ids(tmdb_ids, media_item.type)

    results
    |> MediaAddHelpers.enrich_with_library_status(status)
    |> maybe_enrich_with_request_status(current_user)
    |> Enum.map(fn item ->
      navigate = if item.in_library && item.id, do: ~p"/media/#{item.id}", else: nil
      Map.put(item, :navigate, navigate)
    end)
  end

  # request_status only ever affects the Request button, which only a guest
  # sees, so a viewer who cannot submit a request skips the query entirely
  # rather than paying for two unfiltered list_requests/1 calls whose result
  # they can never act on.
  defp maybe_enrich_with_request_status(results, current_user) do
    if AccountsAuthorization.can_submit_request?(current_user) do
      MediaRequestHelpers.enrich_with_request_status(
        results,
        MediaRequestHelpers.request_status_map()
      )
    else
      results
    end
  end

  # Add.parse_provider_id/1 raises on a non-numeric binary. TMDB ids are always
  # numeric, but one malformed entry must not take down the whole rail.
  defp safe_provider_id(result) do
    Add.parse_provider_id(result.provider_id)
  rescue
    ArgumentError -> nil
  end

  defp mark_in_flight(socket, tmdb_id) do
    assign(
      socket,
      :adding_recommendation_tmdb_ids,
      MapSet.put(socket.assigns.adding_recommendation_tmdb_ids, tmdb_id)
    )
  end

  defp clear_in_flight(socket, tmdb_id) do
    assign(
      socket,
      :adding_recommendation_tmdb_ids,
      MapSet.delete(socket.assigns.adding_recommendation_tmdb_ids, tmdb_id)
    )
  end

  defp mark_owned(recommendations, added) do
    Enum.map(recommendations, fn item ->
      if safe_provider_id(item) == added.tmdb_id do
        item
        |> Map.put(:in_library, true)
        |> Map.put(:id, added.id)
        |> Map.put(:monitored, added.monitored)
        |> Map.put(:navigate, ~p"/media/#{added.id}")
      else
        item
      end
    end)
  end

  defp describe({:changeset, changeset}),
    do: MediaAddHelpers.format_changeset_errors(changeset)

  defp describe({:metadata, _reason}), do: "the metadata service could not be reached"
  defp describe(reason), do: inspect(reason)
end
