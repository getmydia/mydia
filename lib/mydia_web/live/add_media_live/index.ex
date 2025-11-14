defmodule MydiaWeb.AddMediaLive.Index do
  use MydiaWeb, :live_view

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

  defp apply_action(socket, :add_movie, _params) do
    socket
    |> assign(:page_title, "Add Movie")
    |> assign(:media_type, :movie)
    |> load_library_paths(:movies)
    |> load_toolbar_settings(:movie)
  end

  defp apply_action(socket, :add_series, _params) do
    socket
    |> assign(:page_title, "Add Series")
    |> assign(:media_type, :tv_show)
    |> load_library_paths(:series)
    |> load_toolbar_settings(:tv_show)
  end

  defp load_library_paths(socket, type) do
    paths =
      Settings.list_library_paths()
      |> Enum.filter(&(&1.type == type or &1.type == :mixed))
      |> Enum.filter(& &1.monitored)

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

  def handle_event("update_toolbar", %{"field" => field, "value" => value}, socket) do
    field_atom = String.to_atom(field)

    # Parse value based on field type
    parsed_value =
      case field_atom do
        :toolbar_monitored ->
          value == "true"

        _ ->
          value
      end

    {:noreply, assign(socket, field_atom, parsed_value)}
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
        attrs = build_media_item_attrs(full_metadata, config, socket.assigns.media_type)

        case Media.create_media_item(attrs) do
          {:ok, media_item} ->
            # Create episodes for TV shows if monitored
            if socket.assigns.media_type == :tv_show and config.monitored do
              create_episodes_for_media(media_item, full_metadata, config)
            end

            # Stay on page with success message
            {:noreply,
             socket
             |> assign(:adding_index, nil)
             |> assign(
               :added_item_ids,
               Map.put(socket.assigns.added_item_ids, selected.provider_id, media_item.id)
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
    # Set sensible defaults - these persist while the user is on the page
    # The toolbar state is maintained in LiveView assigns
    default_profile = List.first(socket.assigns.quality_profiles)
    default_path = List.first(socket.assigns.library_paths)

    socket
    |> assign(:toolbar_library_path_id, default_path && default_path.id)
    |> assign(:toolbar_quality_profile_id, default_profile && default_profile.id)
    |> assign(:toolbar_monitored, true)
    |> assign(:toolbar_season_monitoring, "all")
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
    # Build changeset from current toolbar settings for the modal
    changeset =
      {%{},
       %{
         quality_profile_id: :string,
         library_path_id: :string,
         monitored: :boolean,
         search_on_add: :boolean,
         season_monitoring: :string
       }}
      |> Ecto.Changeset.cast(
        %{
          quality_profile_id: socket.assigns.toolbar_quality_profile_id,
          library_path_id: socket.assigns.toolbar_library_path_id,
          monitored: socket.assigns.toolbar_monitored,
          search_on_add: socket.assigns.toolbar_search_on_add,
          season_monitoring: socket.assigns.toolbar_season_monitoring
        },
        [:quality_profile_id, :library_path_id, :monitored, :search_on_add, :season_monitoring]
      )

    assign(socket, :config_form, to_form(changeset, as: :config))
  end

  defp validate_config(params, assigns) do
    types = %{
      quality_profile_id: :string,
      library_path_id: :string,
      monitored: :boolean,
      search_on_add: :boolean,
      season_monitoring: :string
    }

    {%{}, types}
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

  defp build_media_item_attrs(metadata, config, media_type) do
    type_string = if media_type == :movie, do: "movie", else: "tv_show"

    %{
      type: type_string,
      title: metadata[:title] || metadata[:name],
      original_title: metadata[:original_title] || metadata[:original_name],
      year: extract_year(metadata),
      tmdb_id: metadata[:id],
      imdb_id: metadata[:imdb_id],
      metadata: metadata,
      monitored: config.monitored
    }
  end

  defp extract_year(metadata) do
    # First check if year is already in metadata
    cond do
      metadata[:year] ->
        metadata[:year]

      metadata[:release_date] || metadata[:first_air_date] ->
        date_value = metadata[:release_date] || metadata[:first_air_date]
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
    require Logger
    # Extract TMDB IDs from search results
    tmdb_ids = Enum.map(results, & &1[:id]) |> Enum.reject(&is_nil/1)

    Logger.info("check_existing_items: search returned #{length(results)} results")
    Logger.info("check_existing_items: TMDB IDs from search: #{inspect(tmdb_ids)}")

    if tmdb_ids == [] do
      %{}
    else
      # Query for existing media items with these TMDB IDs
      type_string = if media_type == :movie, do: "movie", else: "tv_show"

      existing_items = Media.list_media_items(type: type_string)

      Logger.info(
        "check_existing_items: found #{length(existing_items)} items in library of type #{type_string}"
      )

      filtered_items = Enum.filter(existing_items, &(&1.tmdb_id in tmdb_ids))
      Logger.info("check_existing_items: #{length(filtered_items)} items match search results")

      result_map = Map.new(filtered_items, &{&1.tmdb_id, &1.id})
      Logger.info("check_existing_items: result map: #{inspect(result_map)}")

      result_map
    end
  end

  defp create_episodes_for_media(media_item, metadata, config) do
    season_monitoring = config.season_monitoring || "all"

    # Get seasons from metadata
    seasons = metadata[:seasons] || []

    # Determine which seasons to monitor
    seasons_to_monitor =
      case season_monitoring do
        "all" -> seasons
        "first" -> Enum.take(seasons, 1)
        "future" -> filter_future_seasons(seasons)
        "none" -> []
        _ -> []
      end

    # Fetch and create episodes for each season
    Enum.each(seasons_to_monitor, fn season ->
      create_season_episodes(media_item, season)
    end)
  end

  defp filter_future_seasons(seasons) do
    today = Date.utc_today()

    Enum.filter(seasons, fn season ->
      case season[:air_date] do
        nil ->
          false

        date_str ->
          case Date.from_iso8601(date_str) do
            {:ok, date} -> Date.compare(date, today) == :gt
            _ -> false
          end
      end
    end)
  end

  defp create_season_episodes(media_item, season) do
    # Fetch season details with episodes
    config = Metadata.default_relay_config()

    case Metadata.fetch_season(
           config,
           to_string(media_item.tmdb_id),
           season[:season_number]
         ) do
      {:ok, season_data} ->
        episodes = season_data[:episodes] || []

        Enum.each(episodes, fn episode ->
          Media.create_episode(%{
            media_item_id: media_item.id,
            season_number: episode[:season_number],
            episode_number: episode[:episode_number],
            title: episode[:name],
            air_date: parse_air_date(episode[:air_date]),
            metadata: episode,
            monitored: true
          })
        end)

      {:error, _reason} ->
        # Log error but don't fail the entire operation
        :ok
    end
  end

  defp parse_air_date(nil), do: nil
  defp parse_air_date(%Date{} = date), do: date

  defp parse_air_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_air_date(_), do: nil

  defp media_library_path(:movie), do: ~p"/movies"
  defp media_library_path(:tv_show), do: ~p"/tv"
  defp media_library_path(_), do: ~p"/media"

  defp navigate_back(socket) do
    push_navigate(socket, to: media_library_path(socket.assigns.media_type))
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  defp get_poster_url(result) do
    case result[:poster_path] do
      nil -> "/images/no-poster.jpg"
      path -> "https://image.tmdb.org/t/p/w500#{path}"
    end
  end

  defp format_year(nil), do: "N/A"

  defp format_year(result) do
    date_str = result[:release_date] || result[:first_air_date]

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
