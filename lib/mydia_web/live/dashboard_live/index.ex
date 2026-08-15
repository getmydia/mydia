defmodule MydiaWeb.DashboardLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.DiscoverComponents

  require Logger

  alias Mydia.Media
  alias Mydia.Library
  alias Mydia.Downloads
  alias Mydia.Metadata
  alias Mydia.MediaRequests
  alias Mydia.Accounts.Authorization
  alias MydiaWeb.Live.Authorization, as: LiveAuthorization
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

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
        |> assign(:library_status_map, %{})
        |> assign(:adding_item_id, nil)
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, %{})
        |> assign(:selected_item, nil)
        |> assign(:selected_metadata, nil)
        |> assign(:detail_loading, false)
        |> assign(:movie_libraries, MediaAddHelpers.candidate_libraries(:movie))
        |> assign(:show_libraries, MediaAddHelpers.candidate_libraries(:tv_show))
        |> load_dashboard_data()
      else
        socket
        |> assign(:trending_movies_loading, false)
        |> assign(:trending_tv_loading, false)
        |> assign(:trending_movies, [])
        |> assign(:trending_tv, [])
        |> assign(:movie_count, 0)
        |> assign(:tv_show_count, 0)
        |> assign(:active_downloads_count, 0)
        |> assign(:total_storage, "0 GB")
        |> assign(:recent_episodes, [])
        |> assign(:upcoming_episodes, [])
        |> assign(:library_status_map, %{})
        |> assign(:adding_item_id, nil)
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, %{})
        |> assign(:pending_requests_count, 0)
        |> assign(:selected_item, nil)
        |> assign(:selected_metadata, nil)
        |> assign(:detail_loading, false)
        |> assign(:movie_libraries, [])
        |> assign(:show_libraries, [])
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
    # Load basic stats
    movie_count = Media.count_movies()
    tv_show_count = Media.count_tv_shows()
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
  end

  @impl true
  def handle_event(
        "add_to_library",
        %{"tmdb_id" => provider_id, "media_type" => media_type} = params,
        socket
      ) do
    case parse_event_media_type(media_type) do
      {:ok, media_type_atom} ->
        # Set the adding state
        socket = assign(socket, :adding_item_id, provider_id)

        # Start async task to add media
        send(
          self(),
          {:add_media_to_library, provider_id, media_type_atom, params["library_path_id"]}
        )

        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, @unsupported_media_type)}
    end
  end

  def handle_event(
        "request_media",
        %{"tmdb_id" => provider_id, "media_type" => media_type},
        socket
      ) do
    with :ok <- LiveAuthorization.authorize_submit_request(socket),
         {:ok, media_type_atom} <- parse_event_media_type(media_type) do
      socket = assign(socket, :requesting_item_id, provider_id)
      send(self(), {:request_media, provider_id, media_type_atom})
      {:noreply, socket}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, @unsupported_media_type)}
    end
  end

  def handle_event("show_details", %{"id" => id, "type" => type}, socket) do
    with {:ok, media_type} <- parse_event_media_type(type),
         item when not is_nil(item) <- find_trending_item(socket, id, media_type) do
      # Show modal with loading state and trigger metadata fetch
      send(self(), {:fetch_detail_metadata, id, media_type})

      {:noreply,
       socket
       |> assign(:selected_item, item)
       |> assign(:selected_metadata, nil)
       |> assign(:detail_loading, true)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_details", _, socket) do
    {:noreply,
     socket
     |> assign(:selected_item, nil)
     |> assign(:selected_metadata, nil)
     |> assign(:detail_loading, false)}
  end

  @impl true
  def handle_info(:load_trending_movies, socket) do
    case Metadata.trending_movies() do
      {:ok, movies} ->
        enriched_movies =
          movies
          |> Enum.take(10)
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
          |> Enum.take(10)
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

  def handle_info({:fetch_detail_metadata, tmdb_id, media_type}, socket) do
    case MediaAddHelpers.fetch_detail_metadata(tmdb_id, media_type) do
      {:ok, metadata} ->
        {:noreply,
         socket
         |> assign(:selected_metadata, metadata)
         |> assign(:detail_loading, false)}

      {:error, _reason} ->
        # Even on error, stop loading and show what we have from SearchResult
        {:noreply, assign(socket, :detail_loading, false)}
    end
  end

  def handle_info({:add_media_to_library, provider_id, media_type, library_path_id}, socket) do
    # Comes from client params, so a blank string is possible. "" is truthy in
    # Elixir and would reach the changeset as library_path_id: "", failing the
    # foreign key instead of falling back to normal resolution.
    opts =
      case library_path_id do
        id when is_binary(id) and id != "" -> [library_path_id: id]
        _ -> []
      end

    case MediaAddHelpers.handle_add_media_to_library(
           provider_id,
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
         |> assign(:adding_item_id, nil)
         |> assign(:library_status_map, updated_map)
         |> assign(:trending_movies, trending_movies)
         |> assign(:trending_tv, trending_tv)
         |> put_flash(:info, "#{media_item.title} has been added to your library")}

      {:error, {:changeset, changeset}} ->
        {:noreply,
         socket
         |> assign(:adding_item_id, nil)
         |> put_flash(
           :error,
           "Failed to add: #{MediaAddHelpers.format_changeset_errors(changeset)}"
         )}

      {:error, {:metadata, reason}} ->
        {:noreply,
         socket
         |> assign(:adding_item_id, nil)
         |> put_flash(:error, "Failed to fetch metadata: #{inspect(reason)}")}
    end
  end

  def handle_info({:request_media, provider_id, media_type}, socket) do
    trending = socket.assigns.trending_movies ++ socket.assigns.trending_tv

    case Enum.find(trending, &(to_string(&1.provider_id) == provider_id)) do
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

  ## Private Helpers

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

        socket
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, request_status_map)
        |> assign(
          :trending_movies,
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.trending_movies,
            request_status_map
          )
        )
        |> assign(
          :trending_tv,
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.trending_tv,
            request_status_map
          )
        )
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
