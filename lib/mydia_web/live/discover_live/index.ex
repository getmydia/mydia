defmodule MydiaWeb.DiscoverLive.Index do
  use MydiaWeb, :live_view

  import MydiaWeb.DiscoverComponents

  require Logger

  alias Mydia.Media
  alias Mydia.Media.Recommendations
  alias Mydia.Metadata
  alias MydiaWeb.Live.Authorization
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

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Discover")
      |> assign(:languages, MydiaWeb.Languages.all())
      |> assign(:sort_options, @sort_options)
      |> assign(:items, [])
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
      |> assign(:selected_item, nil)
      |> assign(:selected_metadata, nil)
      |> assign(:selected_recommendations, [])
      |> assign(:load_error, nil)
      |> assign(:detail_loading, false)
      |> assign(:libraries, [])
      |> GridDensity.assign_current()

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
        |> assign(:loading, true)
        |> assign(:load_error, nil)
        |> assign(:has_more, false)
        |> assign(:libraries, MediaAddHelpers.candidate_libraries(media_type))

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
       |> assign(:sort_by, "popularity.desc")
       |> assign(:libraries, MediaAddHelpers.candidate_libraries(:movie))}
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
      send(self(), {:load_page, next_page})
      {:noreply, assign(socket, :loading_more, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "add_to_library",
        %{"tmdb_id" => provider_id, "media_type" => media_type} = params,
        socket
      ) do
    case parse_event_media_type(media_type) do
      {:ok, media_type_atom} ->
        socket =
          assign(
            socket,
            :adding_item_ids,
            MapSet.put(socket.assigns.adding_item_ids, provider_id)
          )

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
           find_selectable_item(
             socket.assigns.items,
             socket.assigns.selected_recommendations,
             id
           ) do
      send(self(), {:fetch_detail_metadata, id, media_type})
      send(self(), {:fetch_recommendations, id, media_type})

      {:noreply,
       socket
       |> assign(:selected_item, item)
       |> assign(:selected_metadata, nil)
       |> assign(:selected_recommendations, [])
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

  def handle_event("set_grid_density", %{"density" => density}, socket) do
    {:noreply, GridDensity.put(socket, density)}
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

    socket = handle_load_result(socket, result, :replace)
    {:noreply, socket}
  end

  def handle_info({:load_page, page}, socket) do
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

    socket = handle_load_result(socket, result, :append)
    {:noreply, assign(socket, :loading_more, false)}
  end

  def handle_info({:fetch_detail_metadata, tmdb_id, media_type}, socket) do
    case MediaAddHelpers.fetch_detail_metadata(tmdb_id, media_type) do
      {:ok, metadata} ->
        {:noreply,
         socket
         |> assign(:selected_metadata, metadata)
         |> assign(:detail_loading, false)}

      {:error, _reason} ->
        {:noreply, assign(socket, :detail_loading, false)}
    end
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
         |> assign(:selected_recommendations, recommendations)
         |> put_flash(:info, "#{media_item.title} has been added to your library")}

      {:already_in_library, media_item, updated_map} ->
        items =
          socket.assigns.items
          |> MediaAddHelpers.enrich_with_library_status(updated_map)
          |> MediaRequestHelpers.enrich_with_request_status(socket.assigns.request_status_map)

        {:noreply,
         socket
         |> clear_adding(provider_id)
         |> assign(:library_status_map, updated_map)
         |> assign(:items, items)
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

  def handle_info({:request_media, provider_id, media_type}, socket) do
    # Also resolves against the recommendations rail. A rail title is not in
    # `items`, so searching only that list made a guest's Request click from
    # inside the modal silently do nothing.
    case find_selectable_item(
           socket.assigns.items,
           socket.assigns.selected_recommendations,
           provider_id
         ) do
      nil ->
        {:noreply, assign(socket, :requesting_item_id, nil)}

      item ->
        {:noreply, submit_request(socket, item, media_type)}
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
        |> assign(:selected_recommendations, recommendations)
        |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")

      {:error, reason} ->
        socket
        |> assign(:requesting_item_id, nil)
        |> put_flash(:error, request_error_message(reason))
    end
  end

  @impl true
  def handle_async(:load_recommendations, {:ok, {:ok, results}}, socket) do
    {:noreply, assign(socket, :selected_recommendations, enrich_recommendations(socket, results))}
  end

  def handle_async(:load_recommendations, {:ok, :none}, socket) do
    {:noreply, assign(socket, :selected_recommendations, [])}
  end

  def handle_async(:load_recommendations, {:exit, reason}, socket) do
    Logger.warning("Discover recommendations lookup crashed: #{inspect(reason)}")
    {:noreply, assign(socket, :selected_recommendations, [])}
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

  @doc """
  Resolves a clicked provider id against the current grid page, then the
  recommendations rail.

  A recommendation is not part of the grid page, so resolving against `items`
  alone drops the click and the modal never swaps — a failure that looks like
  nothing happening. Public so it can be exercised without a live process.
  """
  def find_selectable_item(items, recommendations, id) do
    id = to_string(id)

    Enum.find(items, &(to_string(&1.provider_id) == id)) ||
      Enum.find(recommendations, &(to_string(&1.provider_id) == id))
  end

  # Private helpers

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
        |> assign(:has_more, false)
        |> assign(:load_error, nil)
        |> assign(:loading, false)

      {:error, reason} ->
        Logger.warning("Failed to load discover results: #{inspect(reason)}")

        socket
        |> assign(:items, if(mode == :append, do: socket.assigns.items, else: []))
        |> assign(:load_error, reason)
        |> assign(:loading, false)
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
