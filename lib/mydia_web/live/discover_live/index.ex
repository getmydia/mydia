defmodule MydiaWeb.DiscoverLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.AddMediaComponents
  import MydiaWeb.DiscoverComponents

  require Logger

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Media
  alias Mydia.Media.AddDefaults
  alias Mydia.Media.Recommendations
  alias Mydia.Metadata
  alias Mydia.Settings
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.Helpers.DetailModal
  alias MydiaWeb.Live.Helpers.GridDensity
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  import MydiaWeb.GridDensityComponents

  @movie_categories [
    {:trending, "Trending"},
    {:popular, "Popular"},
    {:upcoming, "Upcoming"},
    {:now_playing, "Now Playing"}
  ]

  @tv_categories [
    {:trending, "Trending"},
    {:popular, "Popular"},
    {:on_the_air, "On The Air"},
    {:airing_today, "Airing Today"}
  ]

  @sort_options [
    {"popularity.desc", "Most Popular"},
    {"vote_average.desc", "Highest Rated"},
    {"primary_release_date.desc", "Newest First"},
    {"primary_release_date.asc", "Oldest First"}
  ]

  @unsupported_media_type "That media type is not supported."

  # The provider returns fixed-size pages. Removing owned titles from one can
  # empty it entirely, which would look like the end of the results. Fetch the
  # next page when that happens, bounded so a fully-owned category cannot spin.
  @max_auto_advance 3

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Discover")
      |> assign(:languages, MydiaWeb.Languages.all())
      |> assign(:sort_options, @sort_options)
      |> assign(:items, [])
      |> assign(:visible_items, [])
      |> assign(:loading, true)
      |> assign(:loading_more, false)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:has_more, false)
      |> assign(:genres, [])
      |> assign(:library_status_map, %{})
      |> assign(:adding_item_ids, MapSet.new())
      |> assign(:requesting_item_id, nil)
      |> assign(:request_status_map, %{})
      |> DetailModal.init()
      |> assign(:load_error, nil)
      |> assign(:add_config, nil)
      |> assign(:quality_profiles, Settings.list_quality_profiles())
      |> GridDensity.assign_current()
      |> assign_hide_owned()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    if connected?(socket) do
      media_type = parse_media_type(params["type"])
      category = parse_category(params["category"], media_type)
      search_query = params["q"] || ""
      search_mode = search_query != ""

      # Parse filter params
      selected_genres = parse_genres_param(params["genre"])
      selected_language = params["language"]
      selected_year = parse_year_param(params["year"])
      min_rating = parse_rating_param(params["rating"])
      sort_by = params["sort"] || "popularity.desc"
      page = parse_page_param(params["page"])

      # Determine if filters are active or discover mode is explicitly selected
      filters_active? =
        selected_genres != [] or selected_language != nil or
          selected_year != nil or min_rating != nil

      effective_category =
        if filters_active? or category == :discover, do: :discover, else: category

      categories =
        if media_type == :tv_show, do: @tv_categories, else: @movie_categories

      socket =
        socket
        |> assign(:media_type, media_type)
        |> assign(:category, effective_category)
        |> assign(:categories, categories)
        |> assign(:search_query, search_query)
        |> assign(:search_mode, search_mode)
        |> assign(:selected_genres, selected_genres)
        |> assign(:selected_language, selected_language)
        |> assign(:selected_year, selected_year)
        |> assign(:min_rating, min_rating)
        |> assign(:sort_by, sort_by)
        |> assign(:page, page)
        |> assign(:items, [])
        |> assign_visible_items()
        |> assign(:loading, true)
        |> assign(:load_error, nil)
        |> assign(:has_more, false)

      # Load genres if not loaded yet or media type changed
      socket =
        if socket.assigns.genres == [] do
          send(self(), :load_genres)
          socket
        else
          socket
        end

      # Load library status map
      library_status_map = Media.get_library_status_map()

      socket =
        socket
        |> assign(:library_status_map, library_status_map)
        |> assign(:request_status_map, MediaRequestHelpers.request_status_map())

      send(self(), :load_data)

      {:noreply, socket}
    else
      # Pre-assign defaults for initial (disconnected) render
      {:noreply,
       socket
       |> assign(:media_type, :movie)
       |> assign(:category, :trending)
       |> assign(:categories, @movie_categories)
       |> assign(:search_query, "")
       |> assign(:search_mode, false)
       |> assign(:selected_genres, [])
       |> assign(:selected_language, nil)
       |> assign(:selected_year, nil)
       |> assign(:min_rating, nil)
       |> assign(:sort_by, "popularity.desc")}
    end
  end

  # Events

  @impl true
  def handle_event("switch_media_type", %{"type" => type}, socket) do
    params = %{"type" => type}
    {:noreply, push_patch(socket, to: ~p"/discover?#{params}")}
  end

  def handle_event("switch_category", %{"category" => category}, socket) do
    params = build_url_params(socket.assigns, category: category)
    {:noreply, push_patch(socket, to: ~p"/discover?#{params}")}
  end

  def handle_event("search", %{"q" => query}, socket) do
    query = String.trim(query)

    params =
      if query == "" do
        %{"type" => to_string(socket.assigns.media_type)}
      else
        %{"type" => to_string(socket.assigns.media_type), "q" => query}
      end

    {:noreply, push_patch(socket, to: ~p"/discover?#{params}")}
  end

  def handle_event("clear_search", _, socket) do
    params = %{"type" => to_string(socket.assigns.media_type)}
    {:noreply, push_patch(socket, to: ~p"/discover?#{params}")}
  end

  def handle_event("apply_filters", params, socket) do
    url_params =
      build_url_params(socket.assigns,
        genre: params["genre"],
        language: params["language"],
        year: params["year"],
        rating: params["rating"],
        sort: params["sort"]
      )

    {:noreply, push_patch(socket, to: ~p"/discover?#{url_params}")}
  end

  def handle_event("clear_filters", _, socket) do
    params = %{"type" => to_string(socket.assigns.media_type)}
    {:noreply, push_patch(socket, to: ~p"/discover?#{params}")}
  end

  def handle_event("load_more", _, socket) do
    if socket.assigns.has_more and not socket.assigns.loading_more do
      next_page = socket.assigns.page + 1
      send(self(), {:load_page, next_page, 0})
      {:noreply, assign(socket, :loading_more, true)}
    else
      {:noreply, socket}
    end
  end

  # Reached from the Configure caret. The preview is resolved from the current
  # grid and rail rather than carried in the click's own params: the caret only
  # sends tmdb_id, media_type and title, and the preview panel wants the poster
  # and overview that only a real SearchResult carries.
  def handle_event("open_add_config", params, socket) do
    {:noreply,
     MediaAddHelpers.put_add_config(
       socket,
       params,
       socket.assigns.current_user,
       [socket.assigns.items, socket.assigns.selected_recommendations]
     )}
  end

  def handle_event("close_add_config", _params, socket) do
    {:noreply, MediaAddHelpers.clear_add_config(socket)}
  end

  # Goes through the same in-flight guard a plain click uses. Before the merge
  # this path bypassed it, so a double submit could race itself onto the
  # tmdb_id unique index.
  def handle_event("submit_add_config", %{"config" => params}, socket) do
    case MediaAddHelpers.resolve_add_config_submit(socket, params) do
      {:ok, provider_id, media_type, opts, socket} ->
        {:noreply,
         MediaAddHelpers.queue_add(
           socket,
           provider_id,
           {:add_media_to_library_with_opts, provider_id, media_type, opts}
         )}

      {:halt, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "add_to_library",
        %{"tmdb_id" => provider_id, "media_type" => media_type} = params,
        socket
      ) do
    with :ok <- Authorization.authorize_create_media(socket) do
      case parse_event_media_type(media_type) do
        {:ok, media_type_atom} ->
          {:noreply,
           MediaAddHelpers.queue_add(
             socket,
             provider_id,
             {:add_media_to_library, provider_id, media_type_atom, params["library_path_id"]}
           )}

        :error ->
          {:noreply, put_flash(socket, :error, @unsupported_media_type)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event(
        "request_media",
        %{"tmdb_id" => provider_id, "media_type" => media_type},
        socket
      ) do
    with :ok <- Authorization.authorize_submit_request(socket),
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
         item when not is_nil(item) <-
           DetailModal.find_selectable_item(
             [socket.assigns.items, socket.assigns.selected_recommendations],
             id
           ) do
      {:noreply, DetailModal.select(socket, item, media_type)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_details", _, socket) do
    {:noreply, DetailModal.close(socket)}
  end

  def handle_event("set_grid_density", %{"density" => density}, socket) do
    {:noreply, GridDensity.put(socket, density)}
  end

  def handle_event("toggle_hide_owned", _params, socket) do
    value = not socket.assigns.hide_owned

    # A rejected write leaves the toggle where it was rather than flipping the
    # grid for a preference that will be gone on the next mount. Mirrors
    # `GridDensity.put/2`.
    case persist_hide_owned(socket, value) do
      :ok ->
        {:noreply,
         socket
         |> assign(:hide_owned, value)
         |> assign_visible_items()
         |> maybe_auto_advance(0)}

      :error ->
        {:noreply, put_flash(socket, :error, "Could not save that filter preference")}
    end
  end

  defp persist_hide_owned(socket, value) do
    case socket.assigns[:current_user] do
      nil ->
        :ok

      user ->
        preference = Accounts.get_user_preference!(user)

        case Accounts.update_preference(preference, %{
               "preferences" => %{"discover_hide_owned" => value}
             }) do
          {:ok, _} -> :ok
          {:error, _changeset} -> :error
        end
    end
  end

  # Info handlers

  @impl true
  def handle_info(:load_genres, socket) do
    case Metadata.genres(socket.assigns.media_type) do
      {:ok, genres} ->
        {:noreply, assign(socket, :genres, genres)}

      {:error, reason} ->
        Logger.warning("Failed to load genres: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_info(:load_data, socket) do
    %{
      media_type: media_type,
      search_mode: search_mode,
      search_query: search_query,
      category: category,
      page: page
    } = socket.assigns

    result =
      cond do
        search_mode ->
          config = Metadata.default_relay_config()
          Metadata.search_cached(config, search_query, media_type: media_type, page: page)

        category == :discover ->
          discover_opts = build_discover_opts(socket.assigns)
          Metadata.discover(media_type, discover_opts)

        true ->
          Metadata.fetch_curated_list(category, media_type: media_type, page: page)
      end

    socket =
      socket
      |> handle_load_result(result, :replace)
      |> maybe_auto_advance(0)

    {:noreply, socket}
  end

  def handle_info({:load_page, page, advances}, socket) do
    %{
      media_type: media_type,
      search_mode: search_mode,
      search_query: search_query,
      category: category
    } = socket.assigns

    result =
      cond do
        search_mode ->
          config = Metadata.default_relay_config()
          Metadata.search_cached(config, search_query, media_type: media_type, page: page)

        category == :discover ->
          discover_opts = build_discover_opts(socket.assigns) |> Keyword.put(:page, page)
          Metadata.discover(media_type, discover_opts)

        true ->
          Metadata.fetch_curated_list(category, media_type: media_type, page: page)
      end

    socket =
      socket
      |> handle_load_result(result, :append)
      |> assign(:loading_more, false)
      |> maybe_auto_advance(advances)

    {:noreply, socket}
  end

  def handle_info({:fetch_detail_metadata, provider_id, media_type}, socket) do
    opts = put_source_provider([], provider_id, socket)

    {:noreply,
     DetailModal.put_metadata(
       socket,
       MediaAddHelpers.fetch_detail_metadata(provider_id, media_type, nil, opts)
     )}
  end

  # Runs through start_async rather than inline: on a cache miss this makes a
  # relay call with the config's timeout, and doing that in the handle_info
  # would block the LiveView process. The modal is already on screen by then, so
  # close_details, add and request would all queue behind the fetch and the
  # modal would look frozen.
  def handle_info({:fetch_recommendations, tmdb_id, media_type}, socket) do
    {:noreply,
     start_async(socket, :load_recommendations, fn ->
       Recommendations.for_tmdb_id(tmdb_id, media_type, nil)
     end)}
  end

  def handle_info({:add_media_to_library, provider_id, media_type, library_path_id}, socket) do
    defaults =
      AddDefaults.resolve(socket.assigns.current_user, media_type,
        library_path_id: presence(library_path_id)
      )

    opts =
      defaults
      |> AddDefaults.to_add_opts()
      |> Keyword.put(:search_on_add, defaults.search_on_add)

    add_with_opts(provider_id, media_type, opts, socket)
  end

  def handle_info({:add_media_to_library_with_opts, provider_id, media_type, opts}, socket) do
    add_with_opts(provider_id, media_type, opts, socket)
  end

  def handle_info({:request_media, provider_id, media_type}, socket) do
    # Also resolves against the recommendations rail. A rail title is not in
    # `items`, so searching only that list made a guest's Request click from
    # inside the modal silently do nothing.
    case DetailModal.find_selectable_item(
           [socket.assigns.items, socket.assigns.selected_recommendations],
           provider_id
         ) do
      nil ->
        {:noreply, assign(socket, :requesting_item_id, nil)}

      item ->
        {:noreply, submit_request(socket, item, media_type)}
    end
  end

  # Tells the add flow which provider the clicked id came from.
  #
  # `Relay.search/3` routes every TV search to TVDB, so a TV search result's
  # `provider_id` is a TVDB series id even though the card ships it in a param
  # named `tmdb_id`. `Mydia.Media.Add` defaults to TMDB, so without this the
  # add fetches a TVDB id from `/tmdb/tv/shows/:id`: usually a 404 surfaced as
  # "Failed to fetch metadata: ... Media not found", and worse when the id
  # happens to name a real TMDB show, since the row is then built from the
  # wrong title.
  #
  # Resolved from the item server-side rather than trusted from the click,
  # mirroring `MediaRequestHelpers.build_request_attrs/3`, which has branched on
  # `item.provider` for the Request button all along. An id that no longer
  # resolves against the current page falls through to the TMDB default, which
  # is what trending, discover and the recommendations rail all return.
  defp put_source_provider(opts, provider_id, socket) do
    item =
      DetailModal.find_selectable_item(
        [socket.assigns.items, socket.assigns.selected_recommendations],
        provider_id
      )

    case item && Map.get(item, :provider) do
      :tvdb -> Keyword.put(opts, :provider, :tvdb)
      _ -> opts
    end
  end

  # The picker's blank placeholder ("") and an ordinary card click's nil both
  # mean "no explicit choice"; anything else is a client-supplied library id
  # override for the resolver.
  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp add_with_opts(provider_id, media_type, opts, socket) do
    case MediaAddHelpers.handle_add_media_to_library(
           provider_id,
           media_type,
           socket.assigns.library_status_map,
           nil,
           put_source_provider(opts, provider_id, socket)
         ) do
      {:ok, media_item, updated_map} ->
        items =
          socket.assigns.items
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        # The rail is a second list of the same shape. Without this it keeps the
        # pre-add status and offers "Add to Library" for a title that is now in
        # the library, which a second click would fail on the tmdb_id index.
        recommendations =
          MediaAddHelpers.enrich_with_library_status(
            socket.assigns.selected_recommendations,
            updated_map
          )

        {:noreply,
         socket
         |> clear_adding(provider_id)
         |> assign(:library_status_map, updated_map)
         |> assign(:items, items)
         |> assign_visible_items()
         |> assign(:selected_recommendations, recommendations)
         |> DetailModal.refresh_selected([items, recommendations])
         |> put_flash(:info, "#{media_item.title} has been added to your library")}

      {:already_in_library, media_item, updated_map} ->
        items =
          socket.assigns.items
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        recommendations =
          MediaAddHelpers.enrich_with_library_status(
            socket.assigns.selected_recommendations,
            updated_map
          )

        {:noreply,
         socket
         |> clear_adding(provider_id)
         |> assign(:library_status_map, updated_map)
         |> assign(:items, items)
         |> assign_visible_items()
         |> assign(:selected_recommendations, recommendations)
         |> DetailModal.refresh_selected([items, recommendations])
         |> put_flash(:info, "#{media_item.title} is already in your library")}

      {:error, {:changeset, changeset}} ->
        {:noreply,
         socket
         |> clear_adding(provider_id)
         |> put_flash(
           :error,
           "Failed to add: #{MediaAddHelpers.format_changeset_errors(changeset)}"
         )}

      {:error, {:metadata, reason}} ->
        {:noreply,
         socket
         |> clear_adding(provider_id)
         |> put_flash(:error, "Failed to fetch metadata: #{inspect(reason)}")}
    end
  end

  defp submit_request(socket, item, media_type) do
    case MediaRequestHelpers.handle_request_media(
           item,
           media_type,
           socket.assigns.current_user.id
         ) do
      {:ok, request, status_updates} ->
        request_status_map = Map.merge(socket.assigns.request_status_map, status_updates)

        items =
          MediaRequestHelpers.enrich_with_request_status(socket.assigns.items, request_status_map)

        recommendations =
          MediaRequestHelpers.enrich_with_request_status(
            socket.assigns.selected_recommendations,
            request_status_map
          )

        socket
        |> assign(:requesting_item_id, nil)
        |> assign(:request_status_map, request_status_map)
        |> assign(:items, items)
        |> assign_visible_items()
        |> assign(:selected_recommendations, recommendations)
        |> DetailModal.refresh_selected([items, recommendations])
        |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")

      {:error, reason} ->
        socket
        |> assign(:requesting_item_id, nil)
        |> put_flash(:error, request_error_message(reason))
    end
  end

  @impl true
  def handle_async(:load_recommendations, {:ok, {:ok, results}}, socket) do
    {:noreply,
     DetailModal.put_recommendations(socket, results, &enrich_recommendations(socket, &1))}
  end

  def handle_async(:load_recommendations, {:ok, :none}, socket) do
    {:noreply, DetailModal.put_recommendations(socket, [], & &1)}
  end

  def handle_async(:load_recommendations, {:exit, reason}, socket) do
    Logger.warning("Discover recommendations lookup crashed: #{inspect(reason)}")
    {:noreply, DetailModal.put_recommendations(socket, [], & &1)}
  end

  # Request status matters as much as library status here: without it
  # `requested?/1` reads nil on every card and a guest is offered Request for a
  # title they have already requested, which the duplicate check then rejects.
  defp enrich_recommendations(socket, results) do
    results
    |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
    |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)
  end

  # Four completion clauses all retire the same id. A MapSet rather than a
  # single id so a second add cannot blank the first one's spinner (#459).
  defp clear_adding(socket, provider_id) do
    assign(socket, :adding_item_ids, MapSet.delete(socket.assigns.adding_item_ids, provider_id))
  end

  defp request_error_message(:duplicate_media), do: "That title is already in the library."
  defp request_error_message(:duplicate_request), do: "Someone has already requested that title."

  defp request_error_message(%Ecto.Changeset{} = changeset),
    do: "Could not submit the request: #{MediaAddHelpers.format_changeset_errors(changeset)}"

  defp request_error_message(_), do: "Could not submit the request. Please try again."

  # Private helpers

  defp assign_hide_owned(socket) do
    value =
      case socket.assigns[:current_user] do
        nil -> false
        user -> user |> Accounts.get_user_preference!() |> UserPreference.discover_hide_owned()
      end

    assign(socket, :hide_owned, value)
  end

  defp handle_load_result(socket, result, mode) do
    case result do
      {:ok, %{results: results, page: page, total_pages: total_pages}} ->
        enriched =
          results
          |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        items =
          if mode == :append do
            socket.assigns.items ++ enriched
          else
            enriched
          end

        socket
        |> assign(:items, items)
        |> assign_visible_items()
        |> assign(:page, page)
        |> assign(:total_pages, total_pages)
        |> assign(:has_more, page < total_pages)
        |> assign(:load_error, nil)
        |> assign(:loading, false)

      {:ok, results} when is_list(results) ->
        # Search returns a flat list
        enriched =
          results
          |> MediaAddHelpers.enrich_with_library_status(socket.assigns.library_status_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        items =
          if mode == :append do
            socket.assigns.items ++ enriched
          else
            enriched
          end

        socket
        |> assign(:items, items)
        |> assign_visible_items()
        |> assign(:has_more, false)
        |> assign(:load_error, nil)
        |> assign(:loading, false)

      {:error, reason} ->
        Logger.warning("Failed to load discover results: #{inspect(reason)}")

        socket
        |> assign(:items, if(mode == :append, do: socket.assigns.items, else: []))
        |> assign_visible_items()
        |> assign(:load_error, reason)
        |> assign(:loading, false)
    end
  end

  # Derives :visible_items from :items and :hide_owned. Call this everywhere
  # either of those is assigned, so the template never filters.
  defp assign_visible_items(socket) do
    visible =
      if socket.assigns.hide_owned do
        Enum.reject(socket.assigns.items, & &1.in_library)
      else
        socket.assigns.items
      end

    assign(socket, :visible_items, visible)
  end

  defp maybe_auto_advance(socket, advances) do
    cond do
      not socket.assigns.hide_owned ->
        socket

      advances >= @max_auto_advance ->
        socket

      socket.assigns.visible_items != [] ->
        socket

      not socket.assigns.has_more ->
        socket

      true ->
        send(self(), {:load_page, socket.assigns.page + 1, advances + 1})
        assign(socket, :loading_more, true)
    end
  end

  defp build_discover_opts(assigns) do
    opts = [page: assigns.page]

    opts =
      if assigns.selected_genres != [] do
        Keyword.put(opts, :genres, Enum.join(assigns.selected_genres, ","))
      else
        opts
      end

    opts =
      if assigns.selected_language do
        Keyword.put(opts, :original_language, assigns.selected_language)
      else
        opts
      end

    opts =
      if assigns.selected_year do
        Keyword.put(opts, :year, assigns.selected_year)
      else
        opts
      end

    opts =
      if assigns.min_rating do
        Keyword.put(opts, :min_rating, assigns.min_rating)
      else
        opts
      end

    Keyword.put(opts, :sort_by, assigns.sort_by)
  end

  defp build_url_params(assigns, overrides) do
    params = %{"type" => to_string(assigns.media_type)}

    category = Keyword.get(overrides, :category, to_string(assigns.category))

    params =
      if category != "trending" do
        Map.put(params, "category", category)
      else
        params
      end

    genre = Keyword.get(overrides, :genre)

    params =
      cond do
        genre != nil and genre != "" ->
          Map.put(params, "genre", genre)

        assigns.selected_genres != [] ->
          Map.put(params, "genre", Enum.join(assigns.selected_genres, ","))

        true ->
          params
      end

    language = Keyword.get(overrides, :language, assigns.selected_language)

    params =
      if language && language != "", do: Map.put(params, "language", language), else: params

    year = Keyword.get(overrides, :year, assigns.selected_year)
    params = if year && year != "", do: Map.put(params, "year", to_string(year)), else: params

    rating = Keyword.get(overrides, :rating, assigns.min_rating)

    params =
      if rating && rating != "", do: Map.put(params, "rating", to_string(rating)), else: params

    sort = Keyword.get(overrides, :sort, assigns.sort_by)
    params = if sort && sort != "popularity.desc", do: Map.put(params, "sort", sort), else: params

    params
  end

  # Lenient: URL params are user-typed, so an unknown ?type= falls back to
  # movies rather than erroring.
  defp parse_media_type("tv_show"), do: :tv_show
  defp parse_media_type(_), do: :movie

  # Strict: phx-value payloads are client-controlled, and
  # String.to_existing_atom/1 would raise on anything unexpected and take the
  # LiveView down with it. Match the two known types explicitly instead.
  defp parse_event_media_type("movie"), do: {:ok, :movie}
  defp parse_event_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_event_media_type(_), do: :error

  defp parse_category(nil, _), do: :trending
  defp parse_category("discover", _), do: :discover
  defp parse_category("popular", _), do: :popular
  defp parse_category("upcoming", :movie), do: :upcoming
  defp parse_category("now_playing", :movie), do: :now_playing
  defp parse_category("on_the_air", :tv_show), do: :on_the_air
  defp parse_category("airing_today", :tv_show), do: :airing_today
  defp parse_category(_, _), do: :trending

  defp parse_genres_param(nil), do: []
  defp parse_genres_param(""), do: []

  defp parse_genres_param(genres_string) do
    genres_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_year_param(nil), do: nil
  defp parse_year_param(""), do: nil

  defp parse_year_param(year_string) do
    case Integer.parse(year_string) do
      {year, ""} when year > 1900 and year < 2100 -> year
      _ -> nil
    end
  end

  defp parse_rating_param(nil), do: nil
  defp parse_rating_param(""), do: nil

  defp parse_rating_param(rating_string) do
    case Float.parse(rating_string) do
      {rating, _} when rating >= 0 and rating <= 10 -> rating
      _ -> nil
    end
  end

  defp parse_page_param(nil), do: 1

  defp parse_page_param(page_string) do
    case Integer.parse(page_string) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end
end
