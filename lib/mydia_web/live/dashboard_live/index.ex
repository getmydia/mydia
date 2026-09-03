defmodule MydiaWeb.DashboardLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.DiscoverComponents

  require Logger

  alias Mydia.Accounts
  alias Mydia.Media
  alias Mydia.Media.RecentlyAdded
  alias Mydia.Library
  alias Mydia.Downloads
  alias Mydia.Metadata
  alias Mydia.Metadata.Ref
  alias Mydia.MediaRequests
  alias Mydia.Accounts.Authorization
  alias MydiaWeb.DashboardLive.Components
  alias MydiaWeb.Live.Authorization, as: LiveAuthorization
  alias MydiaWeb.Live.Helpers.DetailModal
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  # How many trending items each rail keeps after a successful fetch (see the
  # Enum.take/2 calls below). The skeleton grid's `count` must match this or
  # the placeholder no longer reserves the same height as the settled row,
  # reintroducing the layout shift this feature exists to prevent.
  @trending_rail_limit 10

  @unsupported_media_type "That media type is not supported."

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")

        socket
        |> assign(:trending_movies_loading, true)
        |> assign(:trending_tv_loading, true)
        |> assign(:trending_movies, [])
        |> assign(:trending_tv, [])
        |> assign(:trending_rail_limit, @trending_rail_limit)
        |> assign(:library_status_map, %{})
        |> assign(:adding_item_ids, MapSet.new())
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, %{})
        |> DetailModal.init()
        |> assign(:add_config, nil)
        |> assign(:quality_profiles, Mydia.Settings.list_quality_profiles())
        |> load_dashboard_data()
      else
        socket
        |> assign(:trending_movies_loading, false)
        |> assign(:trending_tv_loading, false)
        |> assign(:trending_movies, [])
        |> assign(:trending_tv, [])
        |> assign(:trending_rail_limit, @trending_rail_limit)
        |> assign(:movie_count, 0)
        |> assign(:tv_show_count, 0)
        |> assign(:active_downloads_count, 0)
        |> assign(:total_storage, "0 GB")
        |> assign(:recent_episodes, [])
        |> assign(:upcoming_episodes, [])
        |> assign(:recently_added, [])
        |> assign(:library_status_map, %{})
        |> assign(:adding_item_ids, MapSet.new())
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, %{})
        |> assign(:pending_requests_count, 0)
        |> DetailModal.init()
        |> assign(:add_config, nil)
        |> assign(:quality_profiles, Mydia.Settings.list_quality_profiles())
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Dashboard")}
  end

  defp load_dashboard_data(socket) do
    # Load basic stats. The nav hook (MydiaWeb.Live.UserAuth.on_mount
    # :load_navigation_data) runs before mount/3 and already assigns
    # :excluded_categories, so reuse it here rather than recomputing it. This
    # keeps the dashboard's :movie_count / :tv_show_count assigns in sync with
    # the sidebar badges, which the same assign keys drive in Layouts.app.
    excluded_categories = socket.assigns[:excluded_categories] || []
    movie_count = Media.count_movies(exclude_categories: excluded_categories)
    tv_show_count = Media.count_tv_shows(exclude_categories: excluded_categories)
    active_downloads_count = Downloads.count_active_downloads()
    total_storage = Library.total_storage_bytes() |> format_bytes()

    # Load library status map for efficient lookups
    library_status_map = Media.get_library_status_map()

    # Load recent and upcoming content for monitored media
    today = Date.utc_today()
    seven_days_ago = Date.add(today, -7)
    seven_days_ahead = Date.add(today, 7)

    recent_episodes = Media.list_episodes_by_air_date(seven_days_ago, today, monitored: true)
    upcoming_episodes = Media.list_episodes_by_air_date(today, seven_days_ahead, monitored: true)

    # Load pending requests count for admins
    pending_requests_count =
      if Authorization.can_manage_requests?(socket.assigns.current_user) do
        MediaRequests.count_pending_requests()
      else
        0
      end

    # Load trending data asynchronously
    send(self(), :load_trending_movies)
    send(self(), :load_trending_tv)

    # Same window and semantics the player's rail uses
    # (discovery_resolver.ex:39), so both clients agree on what "recently
    # added" means. This is a local query, so unlike the trending rails below
    # it does not need to be pushed off the mount path.
    recently_added =
      RecentlyAdded.list_recent(
        since: DateTime.add(DateTime.utc_now(), -30, :day),
        types: nil,
        limit: 12
      )

    socket
    |> assign(:movie_count, movie_count)
    |> assign(:tv_show_count, tv_show_count)
    |> assign(:active_downloads_count, active_downloads_count)
    |> assign(:total_storage, total_storage)
    |> assign(:library_status_map, library_status_map)
    |> assign(:request_status_map, MediaRequestHelpers.request_status_map())
    |> assign(:recent_episodes, Enum.take(recent_episodes, 10))
    |> assign(:upcoming_episodes, Enum.take(upcoming_episodes, 10))
    |> assign(:pending_requests_count, pending_requests_count)
    |> assign(:recently_added, recently_added)
  end

  @impl true
  def handle_event("dismiss_player_banner", _params, socket) do
    case Accounts.dismiss_player_banner(socket.assigns.current_user) do
      {:ok, _preference} ->
        {:noreply, assign(socket, :player_banner_dismissed, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not dismiss that. Please try again.")}
    end
  end

  def handle_event("open_add_config", params, socket) do
    {:noreply,
     MediaAddHelpers.put_add_config(
       socket,
       params,
       socket.assigns.current_user,
       [socket.assigns.trending_movies, socket.assigns.trending_tv]
     )}
  end

  def handle_event("close_add_config", _params, socket) do
    {:noreply, MediaAddHelpers.clear_add_config(socket)}
  end

  def handle_event("submit_add_config", %{"config" => params}, socket) do
    case MediaAddHelpers.resolve_add_config_submit(socket, params) do
      {:ok, ref, media_type, opts, socket} ->
        {:noreply,
         MediaAddHelpers.queue_add(
           socket,
           ref,
           {:add_media_to_library_with_opts, ref, media_type, opts}
         )}

      {:halt, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "add_to_library",
        %{"ref" => raw_ref, "media_type" => media_type} = params,
        socket
      ) do
    with :ok <- LiveAuthorization.authorize_create_media(socket),
         {:ok, ref} <- Ref.parse(raw_ref) do
      case parse_event_media_type(media_type) do
        {:ok, media_type_atom} ->
          {:noreply,
           MediaAddHelpers.queue_add(
             socket,
             ref,
             {:add_media_to_library, ref, media_type_atom, params["library_path_id"]}
           )}

        :error ->
          {:noreply, put_flash(socket, :error, @unsupported_media_type)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "Could not add that item")}
    end
  end

  def handle_event(
        "request_media",
        %{"ref" => raw_ref, "media_type" => media_type},
        socket
      ) do
    with :ok <- LiveAuthorization.authorize_submit_request(socket),
         {:ok, ref} <- Ref.parse(raw_ref),
         {:ok, media_type_atom} <- parse_event_media_type(media_type) do
      socket = assign(socket, :requesting_item_id, to_string(Ref.id(ref)))
      send(self(), {:request_media, ref, media_type_atom})
      {:noreply, socket}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "Could not request that item")}
    end
  end

  def handle_event("show_details", %{"id" => id, "type" => type}, socket) do
    with {:ok, media_type} <- parse_event_media_type(type),
         item when not is_nil(item) <- find_trending_item(socket, id, media_type) do
      # recommendations: false because this page renders the dialog without a
      # :rail slot. Fetching them would pay for a relay round trip whose result
      # nothing draws.
      {:noreply, DetailModal.select(socket, item, media_type, recommendations: false)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_details", _, socket) do
    {:noreply, DetailModal.close(socket)}
  end

  @impl true
  def handle_info(:load_trending_movies, socket) do
    case Metadata.trending_movies() do
      {:ok, movies} ->
        enriched_movies =
          movies
          |> Enum.take(@trending_rail_limit)
          |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        {:noreply,
         socket
         |> assign(:trending_movies, enriched_movies)
         |> assign(:trending_movies_loading, false)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:trending_movies, [])
         |> assign(:trending_movies_loading, false)}
    end
  end

  def handle_info(:load_trending_tv, socket) do
    case Metadata.trending_tv_shows() do
      {:ok, shows} ->
        enriched_shows =
          shows
          |> Enum.take(@trending_rail_limit)
          |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        {:noreply,
         socket
         |> assign(:trending_tv, enriched_shows)
         |> assign(:trending_tv_loading, false)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:trending_tv, [])
         |> assign(:trending_tv_loading, false)}
    end
  end

  def handle_info({:download_updated, _download_id}, socket) do
    # Just trigger a re-render to update the downloads counter in the sidebar
    # The counter will be recalculated when the layout renders
    {:noreply, socket}
  end

  def handle_info({:fetch_detail_metadata, _tmdb_id, media_type}, socket) do
    # `selected_item` was just found and assigned by the show_details handler
    # that sent this message, so its own ref already carries the provenance.
    ref = Ref.from_search_result(socket.assigns.selected_item)

    {:noreply,
     DetailModal.put_metadata(
       socket,
       MediaAddHelpers.fetch_detail_metadata(ref, media_type)
     )}
  end

  def handle_info({:add_media_to_library, ref, media_type, library_path_id}, socket) do
    case MediaAddHelpers.library_path_opts(library_path_id, media_type) do
      {:error, :unknown_library} ->
        {:noreply,
         socket
         |> clear_adding(ref)
         |> put_flash(:error, "That library is no longer available. Nothing was added.")}

      {:ok, opts} ->
        add_with_opts(ref, media_type, opts, socket)
    end
  end

  def handle_info({:add_media_to_library_with_opts, ref, media_type, opts}, socket) do
    add_with_opts(ref, media_type, opts, socket)
  end

  def handle_info({:request_media, ref, media_type}, socket) do
    trending = socket.assigns.trending_movies ++ socket.assigns.trending_tv
    id_string = to_string(Ref.id(ref))

    case Enum.find(trending, &(to_string(&1.provider_id) == id_string)) do
      nil ->
        {:noreply, assign(socket, :requesting_item_id, nil)}

      item ->
        {:noreply, submit_request(socket, item, media_type)}
    end
  end

  # Grab outcomes are broadcast on the "downloads" topic and handled by
  # MediaLive.Show, which owns the manual-search UI. Ignore them quietly here
  # so the catch-all below keeps meaning "genuinely unexpected message".
  def handle_info({:grab_completed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_failed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_duplicate, _payload}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    # Catch-all for unhandled messages to prevent crashes
    Logger.warning("Unhandled message in DashboardLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  @doc false
  # Exposes @trending_rail_limit so the regression test can assert the
  # skeleton's placeholder count against the same value this module uses,
  # rather than duplicating the literal in both places.
  def trending_rail_limit, do: @trending_rail_limit

  ## Private Helpers

  defp add_with_opts(ref, media_type, opts, socket) do
    opts =
      opts
      |> Keyword.put_new(:actor_type, :user)
      |> Keyword.put_new(:actor_id, socket.assigns.current_user.id)

    case MediaAddHelpers.handle_add_media_to_library(
           ref,
           media_type,
           socket.assigns.library_status_map,
           nil,
           opts
         ) do
      {:ok, media_item, updated_map} ->
        # Re-enrich trending items with updated library status
        trending_movies =
          socket.assigns.trending_movies
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        trending_tv =
          socket.assigns.trending_tv
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        {:noreply,
         socket
         |> clear_adding(ref)
         |> assign(:library_status_map, updated_map)
         |> assign(:trending_movies, trending_movies)
         |> assign(:trending_tv, trending_tv)
         |> DetailModal.refresh_selected([trending_movies, trending_tv])
         |> put_flash(:info, "#{media_item.title} has been added to your library")}

      {:already_in_library, media_item, updated_map} ->
        request_status_map = MediaRequestHelpers.request_status_map()

        trending_movies =
          socket.assigns.trending_movies
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(request_status_map)

        trending_tv =
          socket.assigns.trending_tv
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(request_status_map)

        {:noreply,
         socket
         |> clear_adding(ref)
         |> assign(:library_status_map, updated_map)
         |> assign(:request_status_map, request_status_map)
         |> assign(:trending_movies, trending_movies)
         |> assign(:trending_tv, trending_tv)
         |> DetailModal.refresh_selected([trending_movies, trending_tv])
         |> put_flash(:info, "#{media_item.title} is already in your library")}

      {:error, {:changeset, changeset}} ->
        {:noreply,
         socket
         |> clear_adding(ref)
         |> put_flash(
           :error,
           "Failed to add: #{MediaAddHelpers.format_changeset_errors(changeset)}"
         )}

      {:error, {:metadata, reason}} ->
        {:noreply,
         socket
         |> clear_adding(ref)
         |> put_flash(:error, "Failed to fetch metadata: #{inspect(reason)}")}
    end
  end

  # Four completion clauses all retire the same ref. A MapSet rather than a
  # single ref so a second add cannot blank the first one's spinner (#459).
  defp clear_adding(socket, ref) do
    assign(socket, :adding_item_ids, MapSet.delete(socket.assigns.adding_item_ids, ref))
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    kb = bytes / 1024
    "#{Float.round(kb, 1)} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    mb = bytes / (1024 * 1024)
    "#{Float.round(mb, 1)} MB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 * 1024 do
    gb = bytes / (1024 * 1024 * 1024)
    "#{Float.round(gb, 1)} GB"
  end

  defp format_bytes(bytes) do
    tb = bytes / (1024 * 1024 * 1024 * 1024)
    "#{Float.round(tb, 2)} TB"
  end

  defp submit_request(socket, item, media_type) do
    case MediaRequestHelpers.handle_request_media(
           item,
           media_type,
           socket.assigns.current_user.id
         ) do
      {:ok, request, status_updates} ->
        request_status_map = Map.merge(socket.assigns.request_status_map, status_updates)

        trending_movies =
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.trending_movies,
            request_status_map
          )

        trending_tv =
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.trending_tv,
            request_status_map
          )

        socket
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, request_status_map)
        |> assign(:trending_movies, trending_movies)
        |> assign(:trending_tv, trending_tv)
        |> DetailModal.refresh_selected([trending_movies, trending_tv])
        |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")

      {:error, reason} ->
        socket
        |> assign(:requesting_item_id, nil)
        |> put_flash(:error, request_error_message(reason))
    end
  end

  defp request_error_message(:duplicate_media), do: "That title is already in the library."
  defp request_error_message(:duplicate_request), do: "Someone has already requested that title."

  defp request_error_message(%Ecto.Changeset{} = changeset),
    do: "Could not submit the request: #{MediaAddHelpers.format_changeset_errors(changeset)}"

  defp request_error_message(_), do: "Could not submit the request. Please try again."

  # phx-value payloads are client-controlled, and String.to_existing_atom/1
  # would raise on anything unexpected and take the LiveView down with it.
  # Match the two known types explicitly instead.
  defp parse_event_media_type("movie"), do: {:ok, :movie}
  defp parse_event_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_event_media_type(_), do: :error

  defp find_trending_item(socket, id, :movie),
    do: Enum.find(socket.assigns.trending_movies, &(&1.provider_id == id))

  defp find_trending_item(socket, id, :tv_show),
    do: Enum.find(socket.assigns.trending_tv, &(&1.provider_id == id))
end
