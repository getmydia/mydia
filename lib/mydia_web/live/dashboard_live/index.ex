defmodule MydiaWeb.DashboardLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.DiscoverComponents

  require Logger

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.RegionalSources
  alias MydiaWeb.DashboardLive.RegionalComponents
  alias Mydia.Accounts.HomeLayout
  alias Mydia.Health.Rollup
  alias Mydia.Downloads.ClientHealth
  alias Mydia.Media
  alias Mydia.Media.RecentlyAdded
  alias Mydia.Media.RemoteFilter
  alias Mydia.Library
  alias Mydia.Downloads
  alias Mydia.Metadata
  alias Mydia.Metadata.Ref
  alias Mydia.Plugins.Shelves
  alias Mydia.Accounts.Authorization
  alias MydiaWeb.DashboardLive.Components
  alias MydiaWeb.DashboardLive.ShelfComponents
  alias MydiaWeb.DashboardLive.ShelfRail
  alias MydiaWeb.DashboardLive.HealthComponents
  alias MydiaWeb.DashboardLive.EditHomeComponents
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
    user = socket.assigns[:current_user]
    home_widgets = Accounts.home_widgets(user)

    socket =
      socket
      |> assign(:editing_home, false)
      |> assign(:home_widgets, home_widgets)
      |> assign(:trending_rail_limit, @trending_rail_limit)
      |> assign(:trending_prerequisites_loaded, false)
      |> assign(:library_status_map, %{})
      |> assign(:request_status_map, %{})
      |> assign(:quality_profiles, [])
      |> assign(:adding_item_ids, MapSet.new())
      |> assign(:requesting_item_id, nil)
      |> DetailModal.init()
      |> assign(:add_config, nil)
      |> assign_initial_widget_values()

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
        if user, do: Shelves.subscribe(user)

        Enum.reduce(home_widgets, socket, fn key, acc ->
          load_widget(acc, key)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  defp assign_initial_widget_values(socket) do
    socket
    |> assign(:movie_count, 0)
    |> assign(:tv_show_count, 0)
    |> assign(:active_downloads_count, 0)
    |> assign(:total_storage, "0 GB")
    |> assign(:recent_episodes, [])
    |> assign(:upcoming_episodes, [])
    |> assign(:recently_added, [])
    |> assign(:recently_added_movies, [])
    |> assign(:recently_added_tv, [])
    |> assign(:trending_movies, [])
    |> assign(:trending_tv, [])
    |> assign(:trending_movies_loading, false)
    |> assign(:trending_tv_loading, false)
    |> assign(:regional_country, nil)
    |> assign(:regional_sources, [])
    |> assign(:regional_selected, nil)
    |> assign(:regional_status, :idle)
    |> assign(:regional_items, [])
    |> assign(:shelves, [])
    |> assign(:pending_requests_count, socket.assigns[:pending_requests_count] || 0)
    |> assign(:clients_rollup, %Rollup{
      healthy: 0,
      unhealthy: 0,
      unknown: 0,
      total: 0,
      state: :none
    })
    |> assign(:indexers_rollup, %Rollup{
      healthy: 0,
      unhealthy: 0,
      unknown: 0,
      total: 0,
      state: :none
    })
    |> assign(:media_servers_rollup, %Rollup{
      healthy: 0,
      unhealthy: 0,
      unknown: 0,
      total: 0,
      state: :none
    })
    |> assign(:duplicates_state, :checking)
    |> assign(:duplicates_count, 0)
    |> assign(:trash_summary, %{count: 0, bytes: 0})
    |> assign(:flaresolverr_enabled, false)
    |> assign(:flaresolverr_status, :checking)
  end

  defp load_widget(socket, :library_stats) do
    scope = socket.assigns.current_scope
    excluded_categories = socket.assigns[:excluded_categories] || []
    movie_count = Media.count_movies(scope, exclude_categories: excluded_categories)
    tv_show_count = Media.count_tv_shows(scope, exclude_categories: excluded_categories)
    active_downloads_count = Downloads.count_active_downloads()
    total_storage = Library.total_storage_bytes() |> format_bytes()

    socket
    |> assign(:movie_count, movie_count)
    |> assign(:tv_show_count, tv_show_count)
    |> assign(:active_downloads_count, active_downloads_count)
    |> assign(:total_storage, total_storage)
  end

  defp load_widget(socket, :system_health) do
    user = socket.assigns[:current_user]

    if user && user.role == "admin" do
      client_status = ClientHealth.status_map()
      indexer_status = Mydia.Indexers.Health.status_map()

      media_server_status =
        Mydia.MediaServer.Health.status_map(Mydia.Settings.list_media_server_configs())

      trash_summary = Library.trashed_summary()
      flaresolverr_enabled = Mydia.Indexers.FlareSolverr.enabled?()

      socket
      |> schedule_health_refresh()
      |> assign(:clients_rollup, Rollup.from_status_map(client_status))
      |> assign(:indexers_rollup, Rollup.from_status_map(indexer_status))
      |> assign(:media_servers_rollup, Rollup.from_status_map(media_server_status))
      |> assign(:trash_summary, trash_summary)
      |> assign(:flaresolverr_enabled, flaresolverr_enabled)
      |> assign(:duplicates_state, :checking)
      |> start_async(:duplicate_count, fn ->
        plan = Mydia.Library.Prune.plan()
        length(plan.decisions)
      end)
      |> then(fn s ->
        if flaresolverr_enabled do
          s
          |> assign(:flaresolverr_status, :checking)
          |> start_async(:flaresolverr_status, fn ->
            Mydia.Indexers.FlareSolverr.status()
          end)
        else
          s
          |> cancel_async(:flaresolverr_status)
          |> assign(:flaresolverr_status, :disabled)
        end
      end)
    else
      socket
    end
  end

  defp load_widget(socket, :quick_actions) do
    # Nav hook assigns pending_requests_count; reuse it directly
    socket
  end

  defp load_widget(socket, :recently_added) do
    recently_added =
      RecentlyAdded.list_recent(socket.assigns.current_scope,
        since: DateTime.add(DateTime.utc_now(), -30, :day),
        types: nil,
        limit: 12
      )

    assign(socket, :recently_added, recently_added)
  end

  defp load_widget(socket, :recently_added_movies) do
    recently_added_movies =
      RecentlyAdded.list_recent(socket.assigns.current_scope,
        since: DateTime.add(DateTime.utc_now(), -30, :day),
        types: ["movie"],
        limit: 12
      )

    assign(socket, :recently_added_movies, recently_added_movies)
  end

  defp load_widget(socket, :recently_added_tv) do
    recently_added_tv =
      RecentlyAdded.list_recent(socket.assigns.current_scope,
        since: DateTime.add(DateTime.utc_now(), -30, :day),
        types: ["tv_show"],
        limit: 12
      )

    assign(socket, :recently_added_tv, recently_added_tv)
  end

  defp load_widget(socket, :trending_movies) do
    socket
    |> ensure_trending_prerequisites()
    |> assign(:trending_movies_loading, true)
    |> tap(fn _ -> send(self(), :load_trending_movies) end)
  end

  defp load_widget(socket, :trending_tv) do
    socket
    |> ensure_trending_prerequisites()
    |> assign(:trending_tv_loading, true)
    |> tap(fn _ -> send(self(), :load_trending_tv) end)
  end

  defp load_widget(socket, :regional) do
    pref =
      socket.assigns[:current_user] && Accounts.get_user_preference!(socket.assigns.current_user)

    country = pref && UserPreference.discover_home_country(pref)
    services = if pref, do: UserPreference.discover_streaming_services(pref), else: []
    sources = RegionalSources.home_sources(country, services)

    socket =
      socket
      |> ensure_trending_prerequisites()
      |> assign(:regional_country, country)
      |> assign(:regional_sources, sources)

    case sources do
      [first | _] -> select_regional(socket, RegionalSources.to_param(first))
      [] -> socket
    end
  end

  defp load_widget(socket, :episodes) do
    today = Date.utc_today()
    seven_days_ago = Date.add(today, -7)
    seven_days_ahead = Date.add(today, 7)

    scope = socket.assigns.current_scope

    recent_episodes =
      Media.list_episodes_by_air_date(scope, seven_days_ago, today, monitored: true)

    upcoming_episodes =
      Media.list_episodes_by_air_date(scope, today, seven_days_ahead, monitored: true)

    socket
    |> assign(:recent_episodes, Enum.take(recent_episodes, 10))
    |> assign(:upcoming_episodes, Enum.take(upcoming_episodes, 10))
  end

  # Renders what is stored and asks for a fill of anything stale. The fill runs
  # in a job; its result arrives as `{:shelf_updated, _}`.
  defp load_widget(socket, :shelves) do
    case socket.assigns[:current_user] do
      nil ->
        socket

      user ->
        socket = ensure_trending_prerequisites(socket)
        views = Shelves.list_for(user, :home)
        Shelves.refresh_stale(views)
        assign_shelves(socket, views)
    end
  end

  defp load_widget(socket, _unknown), do: socket

  defp select_regional(socket, param) do
    case RegionalSources.find(socket.assigns.regional_sources, param) do
      nil ->
        socket

      source ->
        country = socket.assigns.regional_country
        # The Home rail mixes movies and TV, so only the certification keys
        # apply; they do not depend on the media type.
        extra =
          socket.assigns.current_scope
          |> RemoteFilter.discover_params(:movie)
          |> Keyword.take([:certification_country, :certification_lte])

        today = Date.utc_today()

        socket
        |> assign(:regional_selected, param)
        |> assign(:regional_status, :loading)
        |> start_async({:regional_rail, param}, fn ->
          RegionalSources.fetch_mixed(source, country, extra, today)
        end)
    end
  end

  defp ensure_trending_prerequisites(socket) do
    if socket.assigns.trending_prerequisites_loaded do
      socket
    else
      user = socket.assigns[:current_user]

      request_status_map =
        if Authorization.can_submit_request?(user) do
          MediaRequestHelpers.request_status_map()
        else
          %{}
        end

      socket
      |> assign(:trending_prerequisites_loaded, true)
      |> assign(:library_status_map, Media.get_library_status_map(socket.assigns.current_scope))
      |> assign(:request_status_map, request_status_map)
      |> assign(:quality_profiles, Mydia.Settings.list_quality_profiles())
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Home")}
  end

  @impl true
  def handle_event("select_regional_source", %{"source" => param}, socket),
    do: {:noreply, select_regional(socket, param)}

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
       rail_lists(socket.assigns)
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

  def handle_event("dismiss_shelf_item", %{"id" => item_id}, socket) do
    user = socket.assigns.current_user
    # An unknown or foreign id is ignored: the reload below is the answer either way.
    Shelves.dismiss_item(user, item_id)
    {:noreply, assign_shelves(socket, Shelves.list_for(user, :home))}
  end

  def handle_event("open_edit_home", _params, socket) do
    {:noreply, assign(socket, :editing_home, true)}
  end

  def handle_event("close_edit_home", _params, socket) do
    {:noreply, assign(socket, :editing_home, false)}
  end

  def handle_event("toggle_home_widget", %{"key" => raw_key}, socket) do
    user = socket.assigns.current_user
    allowed = HomeLayout.available(user) |> Enum.map(& &1.key)
    key = HomeLayout.to_key(raw_key)

    if key && key in allowed do
      new_widgets = HomeLayout.toggle(socket.assigns.home_widgets, key)

      case Accounts.put_home_widgets(user, new_widgets) do
        {:ok, _pref} ->
          socket =
            socket
            |> assign(:home_widgets, new_widgets)
            |> then(fn s ->
              if key in new_widgets do
                load_widget(s, key)
              else
                if key == :system_health, do: cancel_health_refresh(s), else: s
              end
            end)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save your Home layout.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_home_widget", %{"key" => raw_key, "direction" => dir_str}, socket) do
    user = socket.assigns.current_user
    direction = if dir_str == "up", do: :up, else: :down

    case HomeLayout.to_key(raw_key) do
      nil ->
        {:noreply, socket}

      key ->
        new_widgets = HomeLayout.move(socket.assigns.home_widgets, key, direction)

        case Accounts.put_home_widgets(user, new_widgets) do
          {:ok, _pref} ->
            {:noreply, assign(socket, :home_widgets, new_widgets)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save your Home layout.")}
        end
    end
  end

  def handle_event("reset_home_widgets", _params, socket) do
    user = socket.assigns.current_user

    case Accounts.reset_home_widgets(user) do
      {:ok, _pref} ->
        defaults = Accounts.home_widgets(user)

        socket =
          socket
          |> assign(:home_widgets, defaults)
          |> then(fn s ->
            if :system_health in defaults, do: s, else: cancel_health_refresh(s)
          end)
          |> then(fn s ->
            Enum.reduce(defaults, s, fn k, acc -> load_widget(acc, k) end)
          end)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save your Home layout.")}
    end
  end

  @impl true
  def handle_async({:regional_rail, param}, result, socket) do
    if param == socket.assigns.regional_selected do
      socket =
        case result do
          {:ok, {:ok, results}} ->
            items =
              results
              |> RemoteFilter.filter(socket.assigns.current_scope)
              |> Enum.take(@trending_rail_limit * 2)
              |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
              |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

            socket |> assign(:regional_items, items) |> assign(:regional_status, :ok)

          _ ->
            socket |> assign(:regional_items, []) |> assign(:regional_status, :error)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:duplicate_count, {:ok, count}, socket) when is_integer(count) do
    {:noreply,
     socket
     |> assign(:duplicates_count, count)
     |> assign(:duplicates_state, if(count == 0, do: :none, else: :review))}
  end

  def handle_async(:duplicate_count, {:exit, reason}, socket) do
    Logger.warning("Duplicates plan failed in dashboard health widget: #{inspect(reason)}")
    {:noreply, assign(socket, :duplicates_state, :unavailable)}
  end

  def handle_async(:flaresolverr_status, {:ok, %{status: status}}, socket) do
    if socket.assigns[:flaresolverr_enabled] do
      {:noreply, assign(socket, :flaresolverr_status, status)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:flaresolverr_status, {:exit, reason}, socket) do
    if socket.assigns[:flaresolverr_enabled] do
      Logger.warning("FlareSolverr probe failed in dashboard health widget: #{inspect(reason)}")
      {:noreply, assign(socket, :flaresolverr_status, :unhealthy)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load_trending_movies, socket) do
    case Metadata.trending_movies() do
      {:ok, movies} ->
        enriched_movies =
          movies
          |> RemoteFilter.filter(socket.assigns.current_scope)
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
          |> RemoteFilter.filter(socket.assigns.current_scope)
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

  def handle_info({:shelf_updated, _shelf_id}, socket) do
    if :shelves in socket.assigns.home_widgets do
      user = socket.assigns.current_user

      {:noreply,
       socket |> ensure_trending_prerequisites() |> assign_shelves(Shelves.list_for(user, :home))}
    else
      {:noreply, socket}
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
    # Matched on media_type too: the regional rail mixes movies and shows,
    # and TMDB numbers the two catalogs independently, so an id alone can
    # resolve a TV request to a movie that happens to share it.
    case DetailModal.find_selectable_item(rail_lists(socket.assigns), Ref.id(ref), media_type) do
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

  @impl true
  def handle_info(:refresh_health, socket) do
    user = socket.assigns[:current_user]

    if user && user.role == "admin" && :system_health in (socket.assigns[:home_widgets] || []) do
      client_status = ClientHealth.status_map()
      indexer_status = Mydia.Indexers.Health.status_map()

      media_server_status =
        Mydia.MediaServer.Health.status_map(Mydia.Settings.list_media_server_configs())

      trash_summary = Library.trashed_summary()
      flaresolverr_enabled = Mydia.Indexers.FlareSolverr.enabled?()

      socket =
        socket
        |> schedule_health_refresh()
        |> assign(:clients_rollup, Rollup.from_status_map(client_status))
        |> assign(:indexers_rollup, Rollup.from_status_map(indexer_status))
        |> assign(:media_servers_rollup, Rollup.from_status_map(media_server_status))
        |> assign(:trash_summary, trash_summary)
        |> assign(:flaresolverr_enabled, flaresolverr_enabled)
        |> start_async(:duplicate_count, fn ->
          plan = Mydia.Library.Prune.plan()
          length(plan.decisions)
        end)
        |> then(fn s ->
          if flaresolverr_enabled do
            s
            |> assign(:flaresolverr_status, :checking)
            |> start_async(:flaresolverr_status, fn ->
              Mydia.Indexers.FlareSolverr.status()
            end)
          else
            s
            |> cancel_async(:flaresolverr_status)
            |> assign(:flaresolverr_status, :disabled)
          end
        end)

      {:noreply, socket}
    else
      {:noreply, cancel_health_refresh(socket)}
    end
  end

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

  defp schedule_health_refresh(socket) do
    socket = cancel_health_refresh(socket)
    ref = Process.send_after(self(), :refresh_health, 60_000)
    assign(socket, :health_timer_ref, ref)
  end

  defp cancel_health_refresh(socket) do
    if timer = socket.assigns[:health_timer_ref] do
      Process.cancel_timer(timer)
    end

    assign(socket, :health_timer_ref, nil)
  end

  defp add_with_opts(ref, media_type, opts, socket) do
    opts =
      opts
      |> Keyword.put_new(:actor_type, :user)
      |> Keyword.put_new(:actor_id, socket.assigns.current_user.id)

    case MediaAddHelpers.handle_add_media_to_library(
           socket.assigns.current_scope,
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

        regional_items =
          socket.assigns.regional_items
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        {:noreply,
         socket
         |> clear_adding(ref)
         |> assign(:library_status_map, updated_map)
         |> assign(:trending_movies, trending_movies)
         |> assign(:trending_tv, trending_tv)
         |> assign(:regional_items, regional_items)
         |> reenrich_shelves()
         |> then(&DetailModal.refresh_selected(&1, rail_lists(&1.assigns)))
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

        regional_items =
          socket.assigns.regional_items
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(request_status_map)

        {:noreply,
         socket
         |> clear_adding(ref)
         |> assign(:library_status_map, updated_map)
         |> assign(:request_status_map, request_status_map)
         |> assign(:trending_movies, trending_movies)
         |> assign(:trending_tv, trending_tv)
         |> assign(:regional_items, regional_items)
         |> reenrich_shelves()
         |> then(&DetailModal.refresh_selected(&1, rail_lists(&1.assigns)))
         |> put_flash(:info, "#{media_item.title} is already in your library")}

      {:error, :restricted} ->
        {:noreply,
         socket
         |> clear_adding(ref)
         |> put_flash(:error, Media.restricted_message())}

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
           socket.assigns.current_scope,
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

        regional_items =
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.regional_items,
            request_status_map
          )

        socket
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, request_status_map)
        |> assign(:trending_movies, trending_movies)
        |> assign(:trending_tv, trending_tv)
        |> assign(:regional_items, regional_items)
        |> reenrich_shelves()
        |> then(&DetailModal.refresh_selected(&1, rail_lists(&1.assigns)))
        |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")

      {:error, reason} ->
        socket
        |> assign(:requesting_item_id, nil)
        |> put_flash(:error, request_error_message(reason))
    end
  end

  defp request_error_message(:duplicate_media), do: "That title is already in the library."
  defp request_error_message(:duplicate_request), do: "Someone has already requested that title."
  defp request_error_message(:restricted), do: Media.restricted_message()

  defp request_error_message(%Ecto.Changeset{} = changeset),
    do: "Could not submit the request: #{MediaAddHelpers.format_changeset_errors(changeset)}"

  defp request_error_message(_), do: "Could not submit the request. Please try again."

  # phx-value payloads are client-controlled, and String.to_existing_atom/1
  # would raise on anything unexpected and take the LiveView down with it.
  # Match the two known types explicitly instead.
  defp parse_event_media_type("movie"), do: {:ok, :movie}
  defp parse_event_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_event_media_type(_), do: :error

  defp assign_shelves(socket, views) do
    assign(
      socket,
      :shelves,
      ShelfRail.build(views, socket.assigns.library_status_map, socket.assigns.request_status_map)
    )
  end

  # Called after the status maps on the socket changed (an add, a request).
  defp reenrich_shelves(socket) do
    assign(
      socket,
      :shelves,
      ShelfRail.reenrich(
        socket.assigns.shelves,
        socket.assigns.library_status_map,
        socket.assigns.request_status_map
      )
    )
  end

  defp rail_lists(assigns),
    do: [
      assigns.trending_movies,
      assigns.trending_tv,
      assigns.regional_items,
      ShelfRail.items(assigns.shelves)
    ]

  defp find_trending_item(socket, id, media_type),
    do: DetailModal.find_selectable_item(rail_lists(socket.assigns), id, media_type)
end
