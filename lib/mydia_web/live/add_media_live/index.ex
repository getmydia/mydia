defmodule MydiaWeb.AddMediaLive.Index do
  use MydiaWeb, :live_view

  require Logger

  alias Mydia.{Media, Metadata, Settings}
  alias MydiaWeb.Live.Authorization

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:media_type, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:searching, false)
     |> assign(:quality_profiles, Settings.list_quality_profiles())
     |> assign(:library_paths, [])
     |> assign(:metadata_config, Metadata.default_relay_config())
     |> assign(:added_item_ids, %{})
     |> assign(:adding_index, nil)
     |> assign(:show_config_modal, false)
     |> assign(:config_modal_result, nil)
     |> assign(:session, session)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :add_movie, params) do
    socket
    |> assign(:page_title, "Add Movie")
    |> assign(:media_type, :movie)
    |> load_library_paths(:movies)
    |> load_toolbar_settings(:movie)
    |> maybe_trigger_search(params)
  end

  defp apply_action(socket, :add_series, params) do
    socket
    |> assign(:page_title, "Add Series")
    |> assign(:media_type, :tv_show)
    |> load_library_paths(:series)
    |> load_toolbar_settings(:tv_show)
    |> maybe_trigger_search(params)
  end

  # Auto-trigger search if a query parameter is provided
  defp maybe_trigger_search(socket, %{"q" => query}) when is_binary(query) and query != "" do
    send(self(), {:perform_search, query})

    socket
    |> assign(:search_query, query)
    |> assign(:searching, true)
  end

  defp maybe_trigger_search(socket, _params), do: socket

  defp load_library_paths(socket, type) do
    paths =
      Settings.list_library_paths()
      |> Enum.filter(fn lp ->
        (lp.type == type or lp.type == :mixed) and lp.monitored and
          not String.starts_with?(to_string(lp.id), "runtime::")
      end)

    assign(socket, :library_paths, paths)
  end

  ## Event Handlers

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    send(self(), {:perform_search, query})

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:searching, true)
     |> assign(:search_results, [])}
  end

  def handle_event("update_toolbar", params, socket) do
    # Extract which field changed from _target
    target = params["_target"] |> List.first()

    # Get the new value for the changed field
    value = params[target]

    # Parse and assign the value
    socket =
      case target do
        "toolbar_monitored" ->
          assign(socket, :toolbar_monitored, value == "true")

        "toolbar_library_path_id" ->
          assign(socket, :toolbar_library_path_id, value)

        "toolbar_quality_profile_id" ->
          assign(socket, :toolbar_quality_profile_id, value)

        "toolbar_season_monitoring" ->
          assign(socket, :toolbar_season_monitoring, value)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("quick_add", params, socket) do
    with :ok <- Authorization.authorize_create_media(socket) do
      index = String.to_integer(params["index"])
      result = Enum.at(socket.assigns.search_results, index)
      # Default to false if not specified for backward compatibility
      search_on_add = params["search_on_add"] == "true"

      if result do
        config = build_config_from_toolbar(socket)
        # Override search_on_add with the explicit button value
        config = Map.put(config, :search_on_add, search_on_add)

        send(self(), {:create_media_item, index, result, config})

        {:noreply, assign(socket, :adding_index, index)}
      else
        {:noreply, socket}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("open_config_modal", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    result = Enum.at(socket.assigns.search_results, index)

    {:noreply,
     socket
     |> assign(:show_config_modal, true)
     |> assign(:config_modal_result, result)
     |> assign(:config_modal_index, index)
     |> assign_config_form()}
  end

  def handle_event("close_config_modal", _params, socket) do
    {:noreply, assign(socket, :show_config_modal, false)}
  end

  def handle_event("validate_config", %{"config" => config_params}, socket) do
    changeset = validate_config(config_params, socket.assigns)

    {:noreply, assign(socket, :config_form, to_form(changeset, as: :config))}
  end

  def handle_event("submit_config_modal", %{"config" => config_params}, socket) do
    with :ok <- Authorization.authorize_create_media(socket) do
      changeset = validate_config(config_params, socket.assigns)

      if changeset.valid? do
        config = Ecto.Changeset.apply_changes(changeset)
        index = socket.assigns.config_modal_index
        result = socket.assigns.config_modal_result

        send(self(), {:create_media_item, index, result, config})

        {:noreply,
         socket
         |> assign(:show_config_modal, false)
         |> assign(:adding_index, index)}
      else
        {:noreply, assign(socket, :config_form, to_form(changeset, as: :config))}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, navigate_back(socket)}
  end

  ## Async Handlers

  @impl true
  def handle_info({:perform_search, query}, socket) do
    media_type_filter =
      case socket.assigns.media_type do
        :movie -> :movie
        :tv_show -> :tv_show
        _ -> nil
      end

    opts = [media_type: media_type_filter]

    case Metadata.search(socket.assigns.metadata_config, query, opts) do
      {:ok, results} ->
        # Check which results are already in the library
        added_item_ids = check_existing_items(results, socket.assigns.media_type)

        {:noreply,
         socket
         |> assign(:search_results, results)
         |> assign(:added_item_ids, added_item_ids)
         |> assign(:searching, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:searching, false)
         |> put_flash(:error, "Search failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_media_item, _index, selected, config}, socket) do
    # Fetch full metadata
    case Metadata.fetch_by_id(
           socket.assigns.metadata_config,
           selected.provider_id,
           media_type: socket.assigns.media_type
         ) do
      {:ok, full_metadata} ->
        # Create media item
        # Episodes are automatically fetched for TV shows via create_media_item
        attrs = build_media_item_attrs(full_metadata, config, socket.assigns.media_type)
        season_monitoring = config[:season_monitoring] || "all"

        case Media.create_media_item(attrs, season_monitoring: season_monitoring) do
          {:ok, media_item} ->
            maybe_queue_search(media_item, config)

            id_key = String.to_integer(selected.provider_id)

            {:noreply,
             socket
             |> assign(:adding_index, nil)
             |> assign(
               :added_item_ids,
               Map.put(socket.assigns.added_item_ids, id_key, media_item.id)
             )
             |> put_flash(:info, "#{media_item.title} has been added to your library")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:adding_index, nil)
             |> put_flash(:error, "Failed to add: #{format_changeset_errors(changeset)}")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:adding_index, nil)
         |> put_flash(:error, "Failed to fetch metadata: #{inspect(reason)}")}
    end
  end

  ## Private Helpers

  defp load_toolbar_settings(socket, _media_type) do
    configured_default = Settings.get_default_quality_profile()

    socket =
      assign(socket, :default_quality_profile_name, configured_default && configured_default.name)

    # Only initialize toolbar settings if not already set
    # This prevents resetting user selections when handle_params is called again
    if Map.has_key?(socket.assigns, :toolbar_library_path_id) do
      socket
    else
      # Set sensible defaults on first load
      # Note: IDs are stored as strings to match HTML form values
      default_profile = get_default_quality_profile(socket.assigns.quality_profiles)
      default_path = List.first(socket.assigns.library_paths)

      socket
      |> assign(:toolbar_library_path_id, default_path && to_string(default_path.id))
      |> assign(:toolbar_quality_profile_id, default_profile && to_string(default_profile.id))
      |> assign(:toolbar_monitored, true)
      |> assign(:toolbar_season_monitoring, "all")
      |> assign(:toolbar_search_on_add, false)
    end
  end

  # Gets the default quality profile from settings, or falls back to first available
  defp get_default_quality_profile(profiles) do
    # First try to get the configured default from settings
    case Settings.get_default_quality_profile_id() do
      nil ->
        # No default configured, use first profile
        List.first(profiles)

      default_id ->
        # Find the configured default in the profiles list
        # Falls back to first if the configured default no longer exists
        Enum.find(profiles, List.first(profiles), fn p -> p.id == default_id end)
    end
  end

  defp build_config_from_toolbar(socket) do
    %{
      library_path_id: socket.assigns.toolbar_library_path_id,
      quality_profile_id: socket.assigns.toolbar_quality_profile_id,
      monitored: socket.assigns.toolbar_monitored,
      season_monitoring: socket.assigns.toolbar_season_monitoring
    }
  end

  defp assign_config_form(socket) do
    changeset =
      {config_defaults(), config_types()}
      |> Ecto.Changeset.cast(
        %{
          quality_profile_id: socket.assigns.toolbar_quality_profile_id,
          library_path_id: socket.assigns.toolbar_library_path_id,
          monitored: socket.assigns.toolbar_monitored,
          search_on_add: socket.assigns.toolbar_search_on_add,
          season_monitoring: socket.assigns.toolbar_season_monitoring
        },
        Map.keys(config_types())
      )

    assign(socket, :config_form, to_form(changeset, as: :config))
  end

  # The changeset is schemaless, so `apply_changes/1` returns
  # `Map.merge(data, changes)`. Seeding `data` with every key means a field
  # submitted as nil or "" (blank quality profile, unticked checkbox) is still
  # present in the result. With `%{}` as data it would be absent, and the dot
  # access in build_media_item_attrs/3 would raise KeyError. Seeding is
  # structural: it immunises any field added later, not just today's two.
  defp config_defaults do
    %{
      quality_profile_id: nil,
      library_path_id: nil,
      monitored: true,
      search_on_add: false,
      season_monitoring: "all"
    }
  end

  defp config_types do
    %{
      quality_profile_id: :string,
      library_path_id: :string,
      monitored: :boolean,
      search_on_add: :boolean,
      season_monitoring: :string
    }
  end

  defp validate_config(params, assigns) do
    types = config_types()

    {config_defaults(), types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:library_path_id])
    |> validate_profile_exists(assigns.quality_profiles)
    |> validate_path_exists(assigns.library_paths)
  end

  defp validate_profile_exists(changeset, profiles) do
    profile_id = Ecto.Changeset.get_field(changeset, :quality_profile_id)

    if profile_id && !profile_exists?(profiles, profile_id) do
      Ecto.Changeset.add_error(changeset, :quality_profile_id, "does not exist")
    else
      changeset
    end
  end

  defp validate_path_exists(changeset, paths) do
    path_id = Ecto.Changeset.get_field(changeset, :library_path_id)

    if path_id && !path_exists?(paths, path_id) do
      Ecto.Changeset.add_error(changeset, :library_path_id, "does not exist")
    else
      changeset
    end
  end

  # Helper to check if a profile exists in the list, handling both integer IDs and string IDs
  defp profile_exists?(profiles, id) when is_binary(id) do
    Enum.any?(profiles, fn profile ->
      # Compare as strings to handle both "123" and runtime IDs
      to_string(profile.id) == id
    end)
  end

  defp profile_exists?(profiles, id) do
    Enum.any?(profiles, &(&1.id == id))
  end

  # Helper to check if a library path exists in the list, handling both integer IDs and string IDs
  defp path_exists?(paths, id) when is_binary(id) do
    Enum.any?(paths, fn path ->
      # Compare as strings to handle both "123" and runtime IDs like "runtime::library_path::/media/movies"
      to_string(path.id) == id
    end)
  end

  defp path_exists?(paths, id) do
    Enum.any?(paths, &(&1.id == id))
  end

  # Uses the shared auto-search path rather than enqueuing directly: it is
  # already Oban-dedupe-safe (singular insert/1, not insert_all/1) and is what
  # the media detail page uses.
  defp maybe_queue_search(media_item, config) do
    if Map.get(config, :search_on_add) do
      case Mydia.Search.queue_auto_searches([media_item]) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to queue search on add",
            media_item_id: media_item.id,
            reason: inspect(reason)
          )
      end
    end
  end

  defp build_media_item_attrs(metadata, config, media_type) do
    type_string = if media_type == :movie, do: "movie", else: "tv_show"

    base = %{
      type: type_string,
      title: metadata.title,
      original_title: metadata.original_title,
      year: extract_year(metadata),
      imdb_id: metadata.imdb_id,
      metadata: metadata,
      monitored: config.monitored,
      quality_profile_id: config.quality_profile_id,
      library_path_id: config.library_path_id
    }

    # For TV shows fetched via TVDB, store tvdb_id; for movies, store tmdb_id
    if media_type == :tv_show and Map.get(metadata, :provider) == :tvdb do
      Map.put(base, :tvdb_id, metadata.id)
    else
      Map.put(base, :tmdb_id, metadata.id)
    end
  end

  defp extract_year(metadata) do
    # First check if year is already in metadata
    cond do
      metadata.year ->
        metadata.year

      metadata.release_date || metadata.first_air_date ->
        date_value = metadata.release_date || metadata.first_air_date
        extract_year_from_date(date_value)

      true ->
        nil
    end
  end

  defp extract_year_from_date(%Date{} = date), do: date.year

  defp extract_year_from_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date.year
      _ -> nil
    end
  end

  defp extract_year_from_date(_), do: nil

  defp check_existing_items(results, media_type) do
    # Extract provider IDs from search results (provider_id is a string)
    provider_ids =
      results
      |> Enum.map(& &1.provider_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.to_integer/1)

    if provider_ids == [] do
      %{}
    else
      # Query for existing media items with these provider IDs
      type_string = if media_type == :movie, do: "movie", else: "tv_show"

      items = Media.list_media_items(type: type_string)

      # For TV shows, check tvdb_id; for movies, check tmdb_id
      if media_type == :tv_show do
        items
        |> Enum.filter(&(&1.tvdb_id in provider_ids or &1.tmdb_id in provider_ids))
        |> Map.new(fn item ->
          key = item.tvdb_id || item.tmdb_id
          {key, item.id}
        end)
      else
        items
        |> Enum.filter(&(&1.tmdb_id in provider_ids))
        |> Map.new(&{&1.tmdb_id, &1.id})
      end
    end
  end

  defp media_library_path(:movie), do: ~p"/movies"
  defp media_library_path(:tv_show), do: ~p"/tv"
  defp media_library_path(_), do: ~p"/"

  defp navigate_back(socket) do
    push_navigate(socket, to: media_library_path(socket.assigns.media_type))
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp get_poster_url(result) do
    case result.poster_path do
      nil -> "/images/no-poster.svg"
      path -> ImageUrl.poster_url(path)
    end
  end

  defp format_year(nil), do: "N/A"

  defp format_year(result) do
    date_str = result.release_date || result.first_air_date

    case date_str do
      nil ->
        "N/A"

      str ->
        case Date.from_iso8601(str) do
          {:ok, date} -> to_string(date.year)
          _ -> "N/A"
        end
    end
  end

  defp format_rating(nil), do: "N/A"

  defp format_rating(rating) when is_float(rating) do
    Float.round(rating, 1) |> to_string()
  end

  defp format_rating(rating), do: to_string(rating)
end
