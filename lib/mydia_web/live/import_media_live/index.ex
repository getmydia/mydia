defmodule MydiaWeb.ImportMediaLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.{Library, Metadata, Settings}
  alias Mydia.Library.{Scanner, MetadataMatcher, FileGrouper, MediaFile}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.Components

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, initialize_fresh_session(socket)}
  end

  defp initialize_fresh_session(socket) do
    socket
    |> assign(:page_title, "Import Media")
    |> assign(:import_session, nil)
    |> assign(:step, :select_path)
    |> assign(:scan_path, "")
    |> assign(:selected_library_path, nil)
    |> assign(:scanning, false)
    |> assign(:scan_progress, %{files_found: 0})
    |> assign(:matching, false)
    |> assign(:match_progress, %{matched: 0, total: 0})
    |> assign(:importing, false)
    |> assign(:discovered_files, [])
    |> assign(:matched_files, [])
    |> assign(:grouped_files, %{
      series: [],
      movies: [],
      ungrouped: [],
      type_filtered: [],
      sample_filtered: []
    })
    |> assign(:selected_files, MapSet.new())
    |> assign(:scan_stats, %{
      total: 0,
      matched: 0,
      unmatched: 0,
      skipped: 0,
      orphaned: 0,
      type_filtered: 0,
      sample_filtered: 0
    })
    |> assign(:library_paths, Settings.list_library_paths())
    |> assign(:metadata_config, Metadata.default_relay_config())
    |> assign(:import_progress, %{current: 0, total: 0, current_file: nil})
    |> assign(:import_results, %{success: 0, failed: 0, skipped: 0})
    |> assign(:detailed_results, [])
    |> assign(:editing_file_index, nil)
    |> assign(:edit_form, nil)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:editing_series_key, nil)
    |> assign(:series_search_results, [])
    |> assign(:path_suggestions, [])
    |> assign(:show_path_suggestions, false)
    |> assign(:show_type_filtered, false)
    |> assign(:show_sample_filtered, false)
    |> assign(:collapsed_seasons, MapSet.new())
    # Batch edit state (ephemeral, not persisted)
    |> assign(:batch_selected, MapSet.new())
    |> assign(:batch_search_query, "")
    |> assign(:batch_search_results, [])
    |> assign(:batch_selected_match, nil)
    |> assign(:batch_season_value, "")
    # Session recovery prompts
    |> assign(:show_resume_prompt, false)
    |> assign(:pending_session, nil)
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Check if there's a session_id in the URL
    case Map.get(params, "session_id") do
      nil ->
        # No session_id - check for an active session before creating a new one
        handle_no_session_id(socket)

      session_id ->
        # Try to load the session
        case Library.get_import_session(session_id) do
          nil ->
            # Session doesn't exist yet - this is a new import
            {:noreply, assign(socket, :session_id, session_id)}

          session ->
            # Session exists - restore it
            {:noreply, assign(restore_session(socket, session), :session_id, session_id)}
        end
    end
  end

  # Handles the case when user navigates to /import without a session_id
  # Checks for active sessions and prompts user to resume if one exists
  defp handle_no_session_id(socket) do
    user_id = socket.assigns.current_user.id

    case Library.get_active_import_session(user_id) do
      nil ->
        # No active session - generate a new session_id and redirect
        session_id = Ecto.UUID.generate()
        {:noreply, push_patch(socket, to: ~p"/import?session_id=#{session_id}")}

      active_session ->
        # Active session found - show resume prompt
        {:noreply,
         socket
         |> assign(:pending_session, active_session)
         |> assign(:show_resume_prompt, true)}
    end
  end

  ## Event Handlers

  @impl true
  def handle_event("select_library_path", %{"path_id" => path_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      library_path = Enum.find(socket.assigns.library_paths, &(to_string(&1.id) == path_id))

      if library_path do
        # Automatically start scan when library path is selected
        send(self(), {:perform_scan, library_path.path})

        {:noreply,
         socket
         |> assign(:scan_path, library_path.path)
         |> assign(:selected_library_path, library_path)
         |> assign(:scanning, true)
         |> assign(:step, :review)
         |> assign(:discovered_files, [])
         |> assign(:matched_files, [])}
      else
        {:noreply, socket}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_file_selection", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    selected_files = socket.assigns.selected_files

    selected_files =
      if MapSet.member?(selected_files, index) do
        MapSet.delete(selected_files, index)
      else
        MapSet.put(selected_files, index)
      end

    socket =
      socket
      |> assign(:selected_files, selected_files)
      |> persist_session()

    {:noreply, socket}
  end

  def handle_event("select_all_files", _params, socket) do
    # Select only successfully matched files
    matched_indices =
      socket.assigns.matched_files
      |> Enum.with_index()
      |> Enum.filter(fn {file, _idx} -> file.match_result != nil end)
      |> Enum.map(fn {_file, idx} -> idx end)
      |> MapSet.new()

    socket =
      socket
      |> assign(:selected_files, matched_indices)
      |> persist_session()

    {:noreply, socket}
  end

  def handle_event("deselect_all_files", _params, socket) do
    socket =
      socket
      |> assign(:selected_files, MapSet.new())
      |> persist_session()

    {:noreply, socket}
  end

  def handle_event("toggle_season_selection", %{"indices" => indices_str}, socket) do
    # Parse the comma-separated indices
    indices =
      indices_str
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()

    selected_files = socket.assigns.selected_files

    # Check if all episodes in this season are selected
    all_selected = MapSet.subset?(indices, selected_files)

    # Toggle: if all selected, deselect all; otherwise, select all
    selected_files =
      if all_selected do
        MapSet.difference(selected_files, indices)
      else
        MapSet.union(selected_files, indices)
      end

    socket =
      socket
      |> assign(:selected_files, selected_files)
      |> persist_session()

    {:noreply, socket}
  end

  ## Batch Edit Event Handlers

  def handle_event("batch_select_range", %{"indices" => indices_str}, socket) do
    indices =
      indices_str
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()

    batch_selected = MapSet.union(socket.assigns.batch_selected, indices)
    {:noreply, assign(socket, :batch_selected, batch_selected)}
  end

  def handle_event("batch_toggle_file", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    batch_selected = socket.assigns.batch_selected

    batch_selected =
      if MapSet.member?(batch_selected, index) do
        MapSet.delete(batch_selected, index)
      else
        MapSet.put(batch_selected, index)
      end

    {:noreply, assign(socket, :batch_selected, batch_selected)}
  end

  def handle_event("batch_toggle_season", %{"indices" => indices_str}, socket) do
    indices =
      indices_str
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()

    batch_selected = socket.assigns.batch_selected
    all_selected = MapSet.subset?(indices, batch_selected)

    batch_selected =
      if all_selected do
        MapSet.difference(batch_selected, indices)
      else
        MapSet.union(batch_selected, indices)
      end

    {:noreply, assign(socket, :batch_selected, batch_selected)}
  end

  def handle_event("batch_select_all", _params, socket) do
    matched_indices =
      socket.assigns.matched_files
      |> Enum.with_index()
      |> Enum.filter(fn {file, _idx} -> file.match_result != nil end)
      |> Enum.map(fn {_file, idx} -> idx end)
      |> MapSet.new()

    {:noreply, assign(socket, :batch_selected, matched_indices)}
  end

  def handle_event("batch_deselect_all", _params, socket) do
    {:noreply, assign(socket, :batch_selected, MapSet.new())}
  end

  def handle_event("batch_search", %{"value" => query}, socket) do
    if String.trim(query) != "" && String.length(query) >= 2 do
      results =
        search_metadata(
          query,
          socket.assigns.metadata_config,
          socket.assigns.selected_library_path
        )

      {:noreply,
       socket
       |> assign(:batch_search_query, query)
       |> assign(:batch_search_results, results)}
    else
      {:noreply,
       socket
       |> assign(:batch_search_query, query)
       |> assign(:batch_search_results, [])}
    end
  end

  def handle_event("batch_select_search_result", params, socket) do
    match = %{
      title: params["title"],
      provider_id: params["provider_id"],
      year: if(params["year"] != "", do: params["year"], else: nil),
      type: params["type"]
    }

    {:noreply,
     socket
     |> assign(:batch_selected_match, match)
     |> assign(:batch_search_query, match.title)
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_clear_match", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_selected_match, nil)
     |> assign(:batch_search_query, "")
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_update_season", %{"value" => value}, socket) do
    {:noreply, assign(socket, :batch_season_value, value)}
  end

  def handle_event("batch_apply", _params, socket) do
    batch_selected = socket.assigns.batch_selected
    batch_match = socket.assigns.batch_selected_match
    batch_season = socket.assigns.batch_season_value

    has_match_change = batch_match != nil
    has_season_change = String.trim(batch_season) != ""

    if not has_match_change and not has_season_change do
      {:noreply,
       put_flash(
         socket,
         :error,
         "No changes to apply. Select a series/movie or enter a season number."
       )}
    else
      updated_matched_files =
        socket.assigns.matched_files
        |> Enum.with_index()
        |> Enum.map(fn {file, idx} ->
          if MapSet.member?(batch_selected, idx) and file.match_result != nil do
            apply_batch_changes(file, batch_match, batch_season)
          else
            file
          end
        end)

      grouped_files =
        FileGrouper.group_files(normalize_matched_files_types(updated_matched_files))

      count = MapSet.size(batch_selected)

      socket =
        socket
        |> assign(:matched_files, updated_matched_files)
        |> assign(:grouped_files, grouped_files)
        |> assign(:batch_selected, MapSet.new())
        |> assign(:batch_search_query, "")
        |> assign(:batch_search_results, [])
        |> assign(:batch_selected_match, nil)
        |> assign(:batch_season_value, "")
        |> assign(:collapsed_seasons, compute_collapsed_seasons(grouped_files))
        |> persist_session()
        |> put_flash(:info, "Batch edit applied to #{count} file(s)")

      {:noreply, socket}
    end
  end

  def handle_event("start_import", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      if MapSet.size(socket.assigns.selected_files) > 0 do
        send(self(), :perform_import)

        socket =
          socket
          |> assign(:importing, true)
          |> assign(:step, :importing)
          |> assign(
            :import_progress,
            %{current: 0, total: MapSet.size(socket.assigns.selected_files), current_file: nil}
          )
          |> persist_session()

        {:noreply, socket}
      else
        {:noreply, put_flash(socket, :error, "Please select at least one file to import")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("start_over", _params, socket) do
    # Abandon the current session
    if socket.assigns.import_session do
      Library.abandon_active_import_sessions(socket.assigns.current_user.id)
    end

    socket =
      socket
      |> assign(:import_session, nil)
      |> assign(:step, :select_path)
      |> assign(:scan_path, "")
      |> assign(:selected_library_path, nil)
      |> assign(:discovered_files, [])
      |> assign(:matched_files, [])
      |> assign(:grouped_files, %{
        series: [],
        movies: [],
        ungrouped: [],
        type_filtered: []
      })
      |> assign(:selected_files, MapSet.new())
      |> assign(:scan_stats, %{
        total: 0,
        matched: 0,
        unmatched: 0,
        skipped: 0,
        orphaned: 0,
        type_filtered: 0
      })
      |> assign(:import_progress, %{current: 0, total: 0, current_file: nil})
      |> assign(:import_results, %{success: 0, failed: 0, skipped: 0})
      |> assign(:detailed_results, [])
      |> assign(:show_type_filtered, false)
      |> assign(:collapsed_seasons, MapSet.new())

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("resume_session", _params, socket) do
    # Resume the pending session by redirecting to its session_id
    case socket.assigns.pending_session do
      nil ->
        # No pending session - start fresh
        session_id = Ecto.UUID.generate()

        {:noreply,
         socket
         |> assign(:show_resume_prompt, false)
         |> assign(:pending_session, nil)
         |> push_patch(to: ~p"/import?session_id=#{session_id}")}

      session ->
        {:noreply,
         socket
         |> assign(:show_resume_prompt, false)
         |> assign(:pending_session, nil)
         |> push_patch(to: ~p"/import?session_id=#{session.id}")}
    end
  end

  def handle_event("start_fresh", _params, socket) do
    # Abandon any active sessions and start a new one
    user_id = socket.assigns.current_user.id
    Library.abandon_active_import_sessions(user_id)

    session_id = Ecto.UUID.generate()

    {:noreply,
     socket
     |> assign(:show_resume_prompt, false)
     |> assign(:pending_session, nil)
     |> push_patch(to: ~p"/import?session_id=#{session_id}")}
  end

  def handle_event("toggle_type_filtered", _params, socket) do
    {:noreply, assign(socket, :show_type_filtered, !socket.assigns.show_type_filtered)}
  end

  def handle_event("toggle_sample_filtered", _params, socket) do
    {:noreply, assign(socket, :show_sample_filtered, !socket.assigns.show_sample_filtered)}
  end

  def handle_event("toggle_season_collapse", %{"season-id" => season_id}, socket) do
    collapsed = socket.assigns.collapsed_seasons

    collapsed =
      if MapSet.member?(collapsed, season_id),
        do: MapSet.delete(collapsed, season_id),
        else: MapSet.put(collapsed, season_id)

    {:noreply, assign(socket, :collapsed_seasons, collapsed)}
  end

  def handle_event("edit_file", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    matched_file = Enum.at(socket.assigns.matched_files, index)

    if matched_file do
      # Handle both matched and unmatched files
      edit_form =
        if matched_file.match_result do
          # Existing match - populate with current values
          match = matched_file.match_result
          parsed_info = match.parsed_info

          %{
            "title" => match.title,
            "provider_id" => match.provider_id,
            "season" => to_string(parsed_info.season || ""),
            "episodes" => Enum.join(parsed_info.episodes || [], ", "),
            "type" => to_string(parsed_info.type)
          }
        else
          # No match - start with empty form but pre-populate with filename hint
          filename = Path.basename(matched_file.file.path, Path.extname(matched_file.file.path))

          %{
            "title" => filename,
            "provider_id" => "",
            "season" => "",
            "episodes" => "",
            "type" => "movie"
          }
        end

      search_query = if matched_file.match_result, do: matched_file.match_result.title, else: ""

      {:noreply,
       socket
       |> assign(:editing_file_index, index)
       |> assign(:edit_form, edit_form)
       |> assign(:search_query, search_query)
       |> assign(:search_results, [])
       |> assign(:editing_series_key, nil)
       |> assign(:series_search_results, [])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_file_index, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  def handle_event("edit_series", %{"series-key" => key}, socket) do
    # Find the series title from grouped_files to pre-populate search
    series =
      Enum.find(socket.assigns.grouped_files.series, fn s ->
        FileGrouper.series_key(s) == key
      end)

    search_query = if series, do: series.title, else: ""

    {:noreply,
     socket
     |> assign(:editing_series_key, key)
     |> assign(:series_search_results, [])
     # Cancel any active episode edit
     |> assign(:editing_file_index, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_query, search_query)
     |> assign(:search_results, [])}
  end

  def handle_event("cancel_series_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_series_key, nil)
     |> assign(:series_search_results, [])}
  end

  def handle_event("search_for_series_rematch", %{"query" => query}, socket) do
    if String.trim(query) != "" && String.length(query) >= 2 do
      config = socket.assigns.metadata_config

      tv_results =
        case Metadata.search(config, query, media_type: :tv_show) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "tv_show"))
          _ -> []
        end

      {:noreply, assign(socket, :series_search_results, Enum.take(tv_results, 10))}
    else
      {:noreply, assign(socket, :series_search_results, [])}
    end
  end

  def handle_event("select_series_rematch", params, socket) do
    changeset = validate_search_result(params)
    target_key = socket.assigns.editing_series_key

    if changeset.valid? && target_key do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      # Find all episode indices belonging to this series
      episode_indices = find_episode_indices_for_series(socket.assigns.matched_files, target_key)

      # Update each episode's match_result with the new series info, preserving parsed_info
      updated_matched_files =
        Enum.reduce(episode_indices, socket.assigns.matched_files, fn idx, acc ->
          matched_file = Enum.at(acc, idx)
          parsed_info = matched_file.match_result.parsed_info

          updated_match =
            Map.merge(matched_file.match_result, %{
              title: validated_data.title,
              provider_id: validated_data.provider_id,
              provider_type: :tmdb,
              year: validated_data.year,
              manually_edited: true,
              parsed_info: normalize_parsed_info_type(parsed_info)
            })

          List.replace_at(acc, idx, %{matched_file | match_result: updated_match})
        end)

      grouped_files =
        FileGrouper.group_files(normalize_matched_files_types(updated_matched_files))

      count = length(episode_indices)

      socket =
        socket
        |> assign(:matched_files, updated_matched_files)
        |> assign(:grouped_files, grouped_files)
        |> assign(:editing_series_key, nil)
        |> assign(:series_search_results, [])
        |> persist_session()
        |> put_flash(:info, "Updated #{count} episode(s) to \"#{validated_data.title}\"")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit", %{"edit_form" => form_params}, socket) do
    index = socket.assigns.editing_file_index

    if index != nil do
      matched_file = Enum.at(socket.assigns.matched_files, index)

      # Validate form data through changeset
      changeset = validate_edit_form(form_params)

      if changeset.valid? do
        validated_data = Ecto.Changeset.apply_changes(changeset)

        # Build updated or new match result
        updated_match =
          if matched_file.match_result do
            # Update existing match
            Map.merge(matched_file.match_result, %{
              title: validated_data.title,
              provider_id: validated_data.provider_id,
              manually_edited: true,
              parsed_info:
                Map.merge(matched_file.match_result.parsed_info, %{
                  season: Map.get(validated_data, :season),
                  episodes: Map.get(validated_data, :episodes, []),
                  type: validated_data.type
                })
            })
          else
            # Create new match for previously unmatched file
            # Note: provider_type is required by MetadataEnricher (issue #52)
            %{
              title: validated_data.title,
              provider_id: validated_data.provider_id,
              provider_type: :tmdb,
              match_confidence: 1.0,
              manually_edited: true,
              metadata: %{},
              parsed_info: %{
                season: Map.get(validated_data, :season),
                episodes: Map.get(validated_data, :episodes, []),
                type: validated_data.type
              }
            }
          end

        # Update the matched_file in the list
        updated_matched_file = %{matched_file | match_result: updated_match}

        updated_matched_files =
          List.replace_at(socket.assigns.matched_files, index, updated_matched_file)

        # Re-group files to update the hierarchical view
        grouped_files =
          FileGrouper.group_files(normalize_matched_files_types(updated_matched_files))

        # Recalculate scan stats if we just matched an unmatched file
        scan_stats =
          if matched_file.match_result == nil do
            %{
              socket.assigns.scan_stats
              | matched: socket.assigns.scan_stats.matched + 1,
                unmatched: socket.assigns.scan_stats.unmatched - 1
            }
          else
            socket.assigns.scan_stats
          end

        flash_message =
          if matched_file.match_result,
            do: "Match updated successfully",
            else: "Match created successfully"

        socket =
          socket
          |> assign(:matched_files, updated_matched_files)
          |> assign(:grouped_files, grouped_files)
          |> assign(:scan_stats, scan_stats)
          |> assign(:editing_file_index, nil)
          |> assign(:edit_form, nil)
          |> assign(:search_query, "")
          |> assign(:search_results, [])
          |> persist_session()
          |> put_flash(:info, flash_message)

        {:noreply, socket}
      else
        {:noreply,
         socket
         |> put_flash(:error, "Please fix the validation errors")
         |> assign(:edit_form, form_params)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_series", %{"edit_form" => %{"title" => query}}, socket) do
    perform_search(query, socket)
  end

  def handle_event("search_series", %{"query" => query}, socket) do
    perform_search(query, socket)
  end

  def handle_event("select_search_result", params, socket) do
    # Validate search result params
    changeset = validate_search_result(params)

    if changeset.valid? && socket.assigns.edit_form do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      updated_form =
        socket.assigns.edit_form
        |> Map.put("title", validated_data.title)
        |> Map.put("provider_id", validated_data.provider_id)
        |> Map.put("type", to_string(validated_data.type))

      {:noreply,
       socket
       |> assign(:edit_form, updated_form)
       |> assign(:search_results, [])
       |> assign(:search_query, validated_data.title)
       |> persist_session()}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "update_episode_inline",
        %{"index" => index_str, "field" => field, "value" => value},
        socket
      ) do
    index = String.to_integer(index_str)
    matched_file = Enum.at(socket.assigns.matched_files, index)

    if matched_file && matched_file.match_result do
      match = matched_file.match_result
      parsed_info = match.parsed_info

      case parse_inline_field(field, value) do
        {:ok, parsed_value} ->
          current_value =
            case field do
              "season" -> parsed_info.season
              "episodes" -> parsed_info.episodes
            end

          if parsed_value == current_value do
            {:noreply, socket}
          else
            updated_parsed_info =
              case field do
                "season" -> %{parsed_info | season: parsed_value}
                "episodes" -> %{parsed_info | episodes: parsed_value}
              end

            updated_match =
              Map.merge(match, %{parsed_info: updated_parsed_info, manually_edited: true})

            updated_matched_file = %{matched_file | match_result: updated_match}

            updated_matched_files =
              List.replace_at(socket.assigns.matched_files, index, updated_matched_file)

            grouped_files =
              FileGrouper.group_files(normalize_matched_files_types(updated_matched_files))

            socket =
              socket
              |> assign(:matched_files, updated_matched_files)
              |> assign(:grouped_files, grouped_files)
              |> persist_session()

            {:noreply, socket}
          end

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_match", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    matched_file = Enum.at(socket.assigns.matched_files, index)

    if matched_file do
      # Clear the match result but keep the file
      updated_matched_file = %{matched_file | match_result: nil}

      updated_matched_files =
        List.replace_at(socket.assigns.matched_files, index, updated_matched_file)

      # Re-group files
      grouped_files =
        FileGrouper.group_files(normalize_matched_files_types(updated_matched_files))

      # Remove from selected files if it was selected
      selected_files = MapSet.delete(socket.assigns.selected_files, index)

      socket =
        socket
        |> assign(:matched_files, updated_matched_files)
        |> assign(:grouped_files, grouped_files)
        |> assign(:selected_files, selected_files)
        |> persist_session()
        |> put_flash(:info, "Match cleared")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_failed_item", %{"index" => index_str}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      index = String.to_integer(index_str)
      failed_item = Enum.at(socket.assigns.detailed_results, index)

      if failed_item && failed_item.status == :failed do
        # Find the original matched file from scan
        matched_file =
          Enum.find(socket.assigns.matched_files, fn mf ->
            mf.file.path == failed_item.file_path
          end)

        if matched_file do
          # Retry the import
          new_result = import_file_with_details(matched_file, socket.assigns.metadata_config)

          # Update the detailed results
          updated_results = List.replace_at(socket.assigns.detailed_results, index, new_result)

          # Recalculate counts
          success_count = Enum.count(updated_results, &(&1.status == :success))
          failed_count = Enum.count(updated_results, &(&1.status == :failed))
          skipped_count = Enum.count(updated_results, &(&1.status == :skipped))

          {:noreply,
           socket
           |> assign(:detailed_results, updated_results)
           |> assign(:import_results, %{
             success: success_count,
             failed: failed_count,
             skipped: skipped_count
           })
           |> put_flash(:info, "Retried import for #{failed_item.file_name}")}
        else
          {:noreply, put_flash(socket, :error, "Could not find original file data")}
        end
      else
        {:noreply, put_flash(socket, :error, "Invalid retry request")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("retry_all_failed", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      # Get all failed items with their indices
      failed_items_with_indices =
        socket.assigns.detailed_results
        |> Enum.with_index()
        |> Enum.filter(fn {result, _idx} -> result.status == :failed end)

      if failed_items_with_indices == [] do
        {:noreply, put_flash(socket, :info, "No failed items to retry")}
      else
        # Retry each failed item
        updated_results =
          Enum.reduce(failed_items_with_indices, socket.assigns.detailed_results, fn {failed_item,
                                                                                      index},
                                                                                     acc_results ->
            # Find the original matched file
            matched_file =
              Enum.find(socket.assigns.matched_files, fn mf ->
                mf.file.path == failed_item.file_path
              end)

            if matched_file do
              new_result = import_file_with_details(matched_file, socket.assigns.metadata_config)
              List.replace_at(acc_results, index, new_result)
            else
              acc_results
            end
          end)

        # Recalculate counts
        success_count = Enum.count(updated_results, &(&1.status == :success))
        failed_count = Enum.count(updated_results, &(&1.status == :failed))
        skipped_count = Enum.count(updated_results, &(&1.status == :skipped))

        {:noreply,
         socket
         |> assign(:detailed_results, updated_results)
         |> assign(:import_results, %{
           success: success_count,
           failed: failed_count,
           skipped: skipped_count
         })
         |> put_flash(:info, "Retried #{length(failed_items_with_indices)} failed items")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("export_results", _params, socket) do
    # Generate JSON export of detailed results
    export_data = %{
      timestamp: DateTime.utc_now(),
      summary: socket.assigns.import_results,
      results: socket.assigns.detailed_results
    }

    json_data = Jason.encode!(export_data, pretty: true)

    {:noreply,
     socket
     |> push_event("download_export", %{
       filename: "import_results_#{DateTime.utc_now() |> DateTime.to_unix()}.json",
       content: json_data,
       mime_type: "application/json"
     })}
  end

  ## Batch Helpers

  defp apply_batch_changes(file, batch_match, batch_season) do
    match = file.match_result

    # Apply match change (series/movie)
    match =
      if batch_match != nil do
        provider_type =
          case batch_match.type do
            "tv_show" -> :tmdb
            "movie" -> :tmdb
            _ -> Map.get(match, :provider_type, :tmdb)
          end

        match
        |> Map.merge(%{
          title: batch_match.title,
          provider_id: batch_match.provider_id,
          provider_type: provider_type,
          manually_edited: true,
          year: batch_match.year || Map.get(match, :year)
        })
        |> then(fn m ->
          # Update parsed_info type based on match type
          parsed_info = Map.get(m, :parsed_info, %{})

          new_type =
            case batch_match.type do
              "tv_show" -> :tv_show
              "movie" -> :movie
              _ -> Map.get(parsed_info, :type)
            end

          Map.put(m, :parsed_info, Map.put(parsed_info, :type, new_type))
        end)
      else
        match
      end

    # Apply season change (only for TV shows)
    match =
      if String.trim(batch_season) != "" do
        parsed_info = Map.get(match, :parsed_info, %{})
        type = Map.get(parsed_info, :type)

        if type in [:tv_show, "tv_show"] do
          season_num =
            case Integer.parse(batch_season) do
              {n, _} -> n
              :error -> Map.get(parsed_info, :season)
            end

          match
          |> Map.put(:parsed_info, Map.put(parsed_info, :season, season_num))
          |> Map.put(:manually_edited, true)
        else
          match
        end
      else
        match
      end

    %{file | match_result: match}
  end

  ## Season Collapse Helpers

  @high_confidence_threshold 0.8

  defp compute_collapsed_seasons(grouped_files) do
    (grouped_files[:series] || [])
    |> Enum.flat_map(fn series ->
      sk = FileGrouper.series_key(series)

      (series.seasons || [])
      |> Enum.filter(fn season ->
        eps = season.episodes || []

        eps != [] and
          Enum.all?(eps, fn ep ->
            ep.match_result != nil and
              ep.match_result.match_confidence >= @high_confidence_threshold
          end)
      end)
      |> Enum.map(&season_collapse_id(sk, &1.season_number))
    end)
    |> MapSet.new()
  end

  defp season_collapse_id(series_key, season_number), do: "#{series_key}-S#{season_number}"

  ## Private Helpers

  defp find_episode_indices_for_series(matched_files, target_key) do
    matched_files
    |> Enum.with_index()
    |> Enum.filter(fn {mf, _idx} ->
      mf.match_result != nil &&
        mf.match_result.parsed_info != nil &&
        to_string(mf.match_result.parsed_info.type) == "tv_show" &&
        FileGrouper.series_key(mf.match_result) == target_key
    end)
    |> Enum.map(fn {_mf, idx} -> idx end)
  end

  # Session-restored data may store parsed_info.type as a string ("tv_show")
  # but FileGrouper expects atoms (:tv_show). These helpers normalize types.
  defp normalize_parsed_info_type(%{type: type} = parsed_info) when is_binary(type) do
    %{parsed_info | type: String.to_existing_atom(type)}
  end

  defp normalize_parsed_info_type(parsed_info), do: parsed_info

  defp normalize_matched_files_types(matched_files) do
    Enum.map(matched_files, fn
      %{match_result: %{parsed_info: parsed_info} = match} = mf when parsed_info != nil ->
        %{mf | match_result: %{match | parsed_info: normalize_parsed_info_type(parsed_info)}}

      mf ->
        mf
    end)
  end

  defp perform_search(query, socket) do
    if String.trim(query) != "" && String.length(query) >= 2 do
      search_results =
        search_metadata(
          query,
          socket.assigns.metadata_config,
          socket.assigns.selected_library_path
        )

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_results, search_results)}
    else
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_results, [])}
    end
  end

  # Shared metadata search helper used by both individual and batch search
  defp search_metadata(query, config, library_path) do
    library_type = library_path && library_path.type

    # Only search media types compatible with the library
    search_movie? = library_type not in [:series]
    search_tv? = library_type not in [:movies]

    movie_results =
      if search_movie? do
        case Metadata.search(config, query, media_type: :movie) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "movie"))
          _ -> []
        end
      else
        []
      end

    tv_results =
      if search_tv? do
        case Metadata.search(config, query, media_type: :tv_show) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "tv_show"))
          _ -> []
        end
      else
        []
      end

    (movie_results ++ tv_results) |> Enum.take(10)
  end

  ## Async Handlers

  @impl true
  def handle_info({:perform_scan, path}, socket) do
    library_path = socket.assigns.selected_library_path
    # Use library-type-specific file extensions
    extensions = Scanner.extensions_for_library_type(library_path && library_path.type)
    liveview_pid = self()

    # Spawn async task for scanning - keeps LiveView responsive to heartbeats
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      # Progress callback sends updates to the LiveView
      progress_callback = fn file_count ->
        send(liveview_pid, {:scan_progress, file_count})
      end

      result =
        Scanner.scan(path, video_extensions: extensions, progress_callback: progress_callback)

      send(liveview_pid, {:scan_complete, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:scan_progress, file_count}, socket) do
    {:noreply, assign(socket, :scan_progress, %{files_found: file_count})}
  end

  def handle_info({:scan_complete, {:ok, scan_result}}, socket) do
    # Get existing files from database (preload library_path for absolute_path resolution)
    # Only skip files that have valid parent associations (not orphaned)
    existing_files = Library.list_media_files(preload: [:library_path])

    existing_valid_paths =
      existing_files
      |> Enum.reject(&Library.orphaned_media_file?/1)
      |> Enum.map(&MediaFile.absolute_path/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Build map of orphaned files for re-matching
    orphaned_files_map =
      existing_files
      |> Enum.filter(&Library.orphaned_media_file?/1)
      |> Enum.map(fn file ->
        case MediaFile.absolute_path(file) do
          nil -> nil
          abs_path -> {abs_path, file}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # Filter out files that already have valid associations
    # Include orphaned files for re-matching
    new_files =
      Enum.reject(scan_result.files, fn file ->
        MapSet.member?(existing_valid_paths, file.path)
      end)

    # Track which files are orphaned (for re-matching)
    files_to_match =
      Enum.map(new_files, fn file ->
        orphaned_file = Map.get(orphaned_files_map, file.path)

        Map.put(file, :orphaned_media_file_id, orphaned_file && orphaned_file.id)
      end)

    skipped_count = length(scan_result.files) - length(new_files)
    orphaned_count = map_size(orphaned_files_map)

    # Start matching files
    send(self(), {:match_files, files_to_match})

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_progress, %{files_found: 0})
     |> assign(:matching, true)
     |> assign(:discovered_files, scan_result.files)
     |> assign(
       :scan_stats,
       %{
         total: length(files_to_match),
         matched: 0,
         unmatched: 0,
         skipped: skipped_count,
         orphaned: orphaned_count
       }
     )}
  end

  def handle_info({:scan_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_progress, %{files_found: 0})
     |> assign(:step, :select_path)
     |> put_flash(:error, "Scan failed: #{format_error(reason)}")}
  end

  def handle_info({:match_files, files}, socket) do
    library_path = socket.assigns.selected_library_path

    # Spawn async task for metadata matching - keeps LiveView responsive
    liveview_pid = self()
    metadata_config = socket.assigns.metadata_config
    total_files = length(files)
    # New matches use the selected library's configured TV metadata source.
    provider = library_path && library_path.tv_metadata_source

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      # Use Task.async_stream for concurrent matching with back-pressure
      # max_concurrency: 10 limits concurrent HTTP requests to avoid overwhelming metadata-relay
      # timeout: :infinity prevents Task.async_stream from timing out on slow requests
      matched_results =
        files
        |> Task.async_stream(
          fn file ->
            match_result =
              case MetadataMatcher.match_file(file.path,
                     config: metadata_config,
                     provider: provider
                   ) do
                {:ok, match} -> match
                {:error, _reason} -> nil
              end

            # Send progress update back to LiveView
            send(liveview_pid, :match_progress_tick)

            %{
              file: file,
              match_result: match_result,
              import_status: :pending
            }
          end,
          max_concurrency: 10,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.map(fn {:ok, result} -> result end)

      send(liveview_pid, {:match_complete, matched_results, library_path})
    end)

    # Initialize match progress tracking
    {:noreply, assign(socket, :match_progress, %{matched: 0, total: total_files})}
  end

  def handle_info(:match_progress_tick, socket) do
    current = socket.assigns.match_progress.matched + 1

    {:noreply,
     assign(socket, :match_progress, %{socket.assigns.match_progress | matched: current})}
  end

  def handle_info({:match_complete, matched_files, library_path}, socket) do
    # Filter out files whose media type doesn't match the library type
    {compatible_files, type_filtered_files} =
      filter_by_library_type(matched_files, library_path)

    # Filter out sample files, trailers, and extras
    {regular_files, sample_filtered_files} =
      filter_samples_and_extras(compatible_files)

    # Calculate stats
    matched_count = Enum.count(regular_files, &(&1.match_result != nil))
    unmatched_count = length(regular_files) - matched_count
    type_filtered_count = length(type_filtered_files)
    sample_filtered_count = length(sample_filtered_files)

    # Group files hierarchically (only regular files)
    grouped_files =
      regular_files
      |> FileGrouper.group_files()
      |> Map.put(:type_filtered, type_filtered_files)
      |> Map.put(:sample_filtered, sample_filtered_files)

    # Auto-select files with high confidence matches (using indices in regular_files)
    auto_selected =
      regular_files
      |> Enum.with_index()
      |> Enum.filter(fn {file, _idx} ->
        file.match_result != nil && file.match_result.match_confidence >= 0.8
      end)
      |> Enum.map(fn {_file, idx} -> idx end)
      |> MapSet.new()

    socket =
      socket
      |> assign(:matching, false)
      |> assign(:match_progress, %{matched: 0, total: 0})
      |> assign(:step, :review)
      |> assign(:matched_files, regular_files)
      |> assign(:grouped_files, grouped_files)
      |> assign(:collapsed_seasons, compute_collapsed_seasons(grouped_files))
      |> assign(:selected_files, auto_selected)
      |> assign(:scan_stats, %{
        total: length(matched_files),
        matched: matched_count,
        unmatched: unmatched_count,
        skipped: socket.assigns.scan_stats.skipped,
        type_filtered: type_filtered_count,
        sample_filtered: sample_filtered_count
      })
      |> persist_session()

    {:noreply, socket}
  end

  def handle_info(:perform_import, socket) do
    selected_indices = MapSet.to_list(socket.assigns.selected_files)
    selected_files = Enum.map(selected_indices, &Enum.at(socket.assigns.matched_files, &1))

    # Spawn async task for importing - keeps LiveView responsive to updates
    liveview_pid = self()
    metadata_config = socket.assigns.metadata_config

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      # Import each file and send progress updates back to the LiveView
      detailed_results =
        selected_files
        |> Enum.with_index()
        |> Enum.map(fn {matched_file, idx} ->
          # Send progress update before importing each file
          file_name = Path.basename(matched_file.file.path)
          send(liveview_pid, {:import_progress_update, idx + 1, file_name})

          import_file_with_details(matched_file, metadata_config)
        end)

      # Send completion message with all results
      send(liveview_pid, {:import_complete, detailed_results})
    end)

    {:noreply, socket}
  end

  def handle_info({:import_progress_update, current, current_file}, socket) do
    {:noreply,
     assign(socket, :import_progress, %{
       socket.assigns.import_progress
       | current: current,
         current_file: current_file
     })}
  end

  def handle_info({:import_complete, detailed_results}, socket) do
    success_count = Enum.count(detailed_results, &(&1.status == :success))
    failed_count = Enum.count(detailed_results, &(&1.status == :failed))
    skipped_count = Enum.count(detailed_results, &(&1.status == :skipped))

    socket =
      socket
      |> assign(:importing, false)
      |> assign(:step, :complete)
      |> assign(:import_results, %{
        success: success_count,
        failed: failed_count,
        skipped: skipped_count
      })
      |> assign(:detailed_results, detailed_results)
      |> persist_session()

    # Mark session as completed
    if socket.assigns.import_session do
      Library.complete_import_session(socket.assigns.import_session)
    end

    {:noreply, socket}
  end

  # Filters out sample files, trailers, and extras based on parsed_info detection
  defp filter_samples_and_extras(matched_files) do
    Enum.split_with(matched_files, fn matched_file ->
      case matched_file.match_result do
        nil ->
          # No match result - can't determine if it's a sample, keep it
          true

        match ->
          parsed_info = match.parsed_info
          # Keep if NOT a sample, trailer, or extra
          not (parsed_info.is_sample or parsed_info.is_trailer or parsed_info.is_extra)
      end
    end)
  end

  ## Library Type Filtering

  # Filters files by library type compatibility
  # Returns {compatible_files, type_filtered_files}
  defp filter_by_library_type(matched_files, nil), do: {matched_files, []}

  defp filter_by_library_type(matched_files, library_path) do
    case library_path.type do
      :mixed ->
        # Mixed libraries accept all media types
        {matched_files, []}

      :series ->
        # Series-only library: filter out movies
        Enum.split_with(matched_files, fn matched_file ->
          case matched_file.match_result do
            nil -> true
            match -> match.parsed_info.type != :movie
          end
        end)

      :movies ->
        # Movies-only library: filter out TV shows
        Enum.split_with(matched_files, fn matched_file ->
          case matched_file.match_result do
            nil -> true
            match -> match.parsed_info.type != :tv_show
          end
        end)

      _ ->
        # Unknown library type, don't filter
        {matched_files, []}
    end
  end

  ## Session Management

  defp restore_session(socket, session) do
    session_data = session.session_data || %{}
    library_paths = Settings.list_library_paths()

    # Restore the selected library path from the scan_path
    selected_library_path =
      if session.scan_path do
        Enum.find(library_paths, fn lp -> lp.path == session.scan_path end)
      else
        nil
      end

    socket
    |> assign(:page_title, "Import Media")
    |> assign(:import_session, session)
    |> assign(:step, session.step)
    |> assign(:scan_path, session.scan_path || "")
    |> assign(:selected_library_path, selected_library_path)
    |> assign(:scanning, false)
    |> assign(:matching, false)
    |> assign(:importing, session.step == :importing)
    |> assign(:discovered_files, Map.get(session_data, "discovered_files", []))
    |> assign(
      :matched_files,
      restore_matched_files(Map.get(session_data, "matched_files", []))
    )
    |> assign(
      :grouped_files,
      Map.get(
        session_data,
        "grouped_files",
        %{"series" => [], "movies" => [], "ungrouped" => [], "type_filtered" => []}
      )
      |> atomize_grouped_files()
    )
    |> assign(
      :selected_files,
      Map.get(session_data, "selected_files", []) |> MapSet.new()
    )
    |> assign(
      :scan_stats,
      if session.scan_stats && session.scan_stats != %{} do
        atomize_keys(session.scan_stats)
      else
        %{total: 0, matched: 0, unmatched: 0, skipped: 0, orphaned: 0, type_filtered: 0}
      end
    )
    |> assign(:library_paths, library_paths)
    |> assign(:metadata_config, Metadata.default_relay_config())
    |> assign(
      :import_progress,
      if session.import_progress && session.import_progress != %{} do
        atomize_keys(session.import_progress)
      else
        %{current: 0, total: 0, current_file: nil}
      end
    )
    |> assign(
      :import_results,
      if session.import_results && session.import_results != %{} do
        atomize_keys(session.import_results)
      else
        %{success: 0, failed: 0, skipped: 0}
      end
    )
    |> assign(
      :detailed_results,
      Map.get(session_data, "detailed_results", [])
      |> atomize_detailed_results()
    )
    |> assign(:editing_file_index, nil)
    |> assign(:edit_form, nil)
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:editing_series_key, nil)
    |> assign(:series_search_results, [])
    |> assign(:path_suggestions, [])
    |> assign(:show_path_suggestions, false)
    |> assign(:show_type_filtered, false)
    |> assign(:show_sample_filtered, false)
    # Batch edit state (ephemeral, not persisted)
    |> assign(:batch_selected, MapSet.new())
    |> assign(:batch_search_query, "")
    |> assign(:batch_search_results, [])
    |> assign(:batch_selected_match, nil)
    |> assign(:batch_season_value, "")
    |> then(fn socket ->
      assign(socket, :collapsed_seasons, compute_collapsed_seasons(socket.assigns.grouped_files))
    end)
  end

  defp persist_session(socket) do
    session_id = socket.assigns[:session_id]
    user_id = socket.assigns.current_user.id

    # If no session_id in assigns, skip persistence
    if session_id == nil do
      socket
    else
      session_data = %{
        "discovered_files" => socket.assigns.discovered_files,
        "matched_files" => prepare_matched_files_for_storage(socket.assigns.matched_files),
        "grouped_files" => prepare_grouped_files_for_storage(socket.assigns.grouped_files),
        "selected_files" => MapSet.to_list(socket.assigns.selected_files),
        "detailed_results" => socket.assigns.detailed_results
      }

      attrs = %{
        step: socket.assigns.step,
        scan_path: socket.assigns.scan_path,
        session_data: session_data,
        scan_stats: socket.assigns.scan_stats,
        import_progress: socket.assigns.import_progress,
        import_results: socket.assigns.import_results
      }

      # Check if session already exists
      case Library.get_import_session(session_id) do
        nil ->
          # Create new session with the specific ID
          case Library.create_import_session(
                 Map.merge(attrs, %{id: session_id, user_id: user_id})
               ) do
            {:ok, new_session} ->
              assign(socket, :import_session, new_session)

            {:error, _changeset} ->
              socket
          end

        existing_session ->
          # Update existing session
          case Library.update_import_session(existing_session, attrs) do
            {:ok, updated_session} ->
              assign(socket, :import_session, updated_session)

            {:error, _changeset} ->
              socket
          end
      end
    end
  end

  defp prepare_matched_files_for_storage(matched_files) do
    Enum.map(matched_files, fn matched_file ->
      %{
        "file" => to_storable_map(matched_file.file),
        "match_result" => to_storable_map(matched_file.match_result),
        "import_status" => matched_file.import_status
      }
    end)
  end

  defp prepare_grouped_files_for_storage(grouped_files) do
    %{
      "series" => Enum.map(grouped_files.series || [], &to_storable_map/1),
      "movies" => Enum.map(grouped_files.movies || [], &to_storable_map/1),
      "ungrouped" => Enum.map(grouped_files.ungrouped || [], &to_storable_map/1),
      "type_filtered" => Enum.map(grouped_files[:type_filtered] || [], &to_storable_map/1)
    }
  end

  # Recursively convert structs to maps for storage
  # Converts all atom keys to strings and handles special types like DateTime
  defp to_storable_map(nil), do: nil

  defp to_storable_map(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp to_storable_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {to_string(k), to_storable_map(v)} end)
    |> Map.new()
  end

  defp to_storable_map(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {to_string(k), to_storable_map(v)} end)
    |> Map.new()
  end

  defp to_storable_map(list) when is_list(list) do
    Enum.map(list, &to_storable_map/1)
  end

  defp to_storable_map(value), do: value

  defp restore_matched_files(stored_files) do
    Enum.map(stored_files, fn stored_file ->
      %{
        file: atomize_keys(stored_file["file"]),
        match_result:
          if stored_file["match_result"] do
            atomize_match_result(stored_file["match_result"])
          else
            nil
          end,
        import_status: String.to_atom(stored_file["import_status"] || "pending")
      }
    end)
  end

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        # Use String.to_atom/1 for persistence data since we control the keys
        {String.to_atom(key), atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp atomize_match_result(nil), do: nil

  defp atomize_match_result(match) when is_map(match) do
    match
    |> Map.new(fn
      {"parsed_info", parsed_info} when is_map(parsed_info) ->
        {:parsed_info, atomize_keys(parsed_info)}

      {"metadata", metadata} when is_map(metadata) ->
        {:metadata, atomize_keys(metadata)}

      # provider_type needs to be converted back to an atom
      {"provider_type", value} when is_binary(value) ->
        {:provider_type, String.to_atom(value)}

      {key, value} when is_binary(key) ->
        {String.to_atom(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp atomize_grouped_files(grouped) when is_map(grouped) do
    %{
      series: atomize_keys(Map.get(grouped, "series", [])),
      movies: atomize_keys(Map.get(grouped, "movies", [])),
      ungrouped: atomize_keys(Map.get(grouped, "ungrouped", [])),
      type_filtered: restore_matched_files(Map.get(grouped, "type_filtered", []))
    }
  end

  defp atomize_detailed_results(results) when is_list(results) do
    Enum.map(results, &atomize_keys/1)
  end

  ## Private Helpers

  defp import_file_with_details(%{match_result: nil, file: file}, _config) do
    # Standard library file without metadata match - report failure
    %{
      file_path: file.path,
      file_name: Path.basename(file.path),
      status: :failed,
      media_item_title: nil,
      error_message: "No metadata match found for this file",
      action_taken: nil,
      metadata: %{size: file.size}
    }
  end

  defp import_file_with_details(%{file: file, match_result: match_result}, config) do
    # Check if this file is orphaned and needs re-matching
    media_file_result =
      if file[:orphaned_media_file_id] do
        # Use existing orphaned media file - don't update it yet
        # The enricher will handle associating it with the media item
        try do
          media_file = Library.get_media_file!(file.orphaned_media_file_id)
          {:ok, media_file}
        rescue
          _ -> {:error, :not_found}
        end
      else
        # Create new media file record with relative path
        # Find matching library_path and calculate relative_path
        library_paths = Settings.list_library_paths()

        {library_path_id, relative_path} =
          calculate_relative_path_for_import(file.path, library_paths)

        Library.create_scanned_media_file(%{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file.size,
          verified_at: DateTime.utc_now()
        })
      end

    case media_file_result do
      {:ok, media_file} ->
        # Enrich with metadata
        case Library.MetadataEnricher.enrich(match_result,
               config: config,
               media_file_id: media_file.id
             ) do
          {:ok, media_item} ->
            %{
              file_path: file.path,
              file_name: Path.basename(file.path),
              status: :success,
              media_item_title: match_result.title,
              error_message: nil,
              action_taken: build_success_message(match_result, file[:orphaned_media_file_id]),
              metadata: %{
                size: file.size,
                media_item_id: media_item.id,
                year: match_result.year,
                type: match_result.parsed_info.type
              }
            }

          {:error, reason} ->
            %{
              file_path: file.path,
              file_name: Path.basename(file.path),
              status: :failed,
              media_item_title: match_result.title,
              error_message: "Failed to enrich metadata: #{format_error(reason)}",
              action_taken: nil,
              metadata: %{size: file.size}
            }
        end

      {:error, changeset} ->
        error_msg = format_changeset_errors_friendly(changeset)

        %{
          file_path: file.path,
          file_name: Path.basename(file.path),
          status: :failed,
          media_item_title: match_result.title,
          error_message: error_msg,
          action_taken: nil,
          metadata: %{size: file.size}
        }
    end
  rescue
    error ->
      %{
        file_path: file.path,
        file_name: Path.basename(file.path),
        status: :failed,
        media_item_title: match_result && match_result.title,
        error_message: friendly_db_error(error),
        action_taken: nil,
        metadata: %{size: file.size}
      }
  end

  @doc false
  # Maps a raised exception to a user-friendly per-file error message.
  #
  # A `varchar(255)` overflow on PostgreSQL raises a `Postgrex.Error` with
  # pg_code `:string_data_right_truncation` (22001) from `Repo.insert` rather
  # than returning an `{:error, %Ecto.Changeset{}}` — Ecto only maps *declared*
  # constraint violations to changeset errors, and these free-text columns
  # declare no length constraint. Referencing the `Postgrex.Error` struct is
  # safe under SQLite (the dep is compiled in; the match simply never succeeds).
  #
  # Public (with `@doc false`) so it can be unit-tested without a live Postgres
  # connection by synthesizing a `%Postgrex.Error{}`.
  def friendly_db_error(%Postgrex.Error{postgres: %{code: :string_data_right_truncation} = pg}) do
    location =
      case {Map.get(pg, :table), Map.get(pg, :column)} do
        {table, column} when is_binary(table) and is_binary(column) ->
          " (#{table}.#{column})"

        _ ->
          ""
      end

    "A metadata value is too long to store#{location}. " <>
      "If your database schema is out of date, run database migrations to widen the affected column."
  end

  def friendly_db_error(error) do
    "Unexpected error: #{Exception.message(error)}"
  end

  defp build_success_message(match_result, _is_orphaned) do
    media_type =
      case match_result.parsed_info.type do
        :tv_show ->
          if match_result.parsed_info.season do
            "TV Show S#{String.pad_leading("#{match_result.parsed_info.season}", 2, "0")}"
          else
            "TV Show"
          end

        _ ->
          "Movie"
      end

    "Imported #{media_type}: '#{match_result.title}'"
  end

  @doc false
  # Formats changeset errors with user-friendly messages for known issues.
  # Public (with `@doc false`) so the friendly-error mapping can be unit-tested.
  def format_changeset_errors_friendly(%Ecto.Changeset{} = changeset) do
    # Check for specific known error patterns
    cond do
      has_size_error?(changeset) ->
        "File appears to be empty or incomplete (0 bytes). This usually means the download was interrupted or the file is a placeholder."

      has_library_type_mismatch?(changeset) ->
        "File type doesn't match the library type"

      has_truncation_error?(changeset) ->
        "A metadata value is too long to store. If your database schema is out of date, run database migrations to widen the affected column."

      true ->
        "Database error: #{format_changeset_errors(changeset)}"
    end
  end

  def format_changeset_errors_friendly(other), do: format_error(other)

  defp has_size_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:size, {_msg, _opts}} -> true
      _ -> false
    end)
  end

  # Defends the `{:error, changeset}` branch in case any path ever surfaces a
  # length overflow as a changeset error (e.g. a value-too-long validation
  # rather than a raised Postgrex.Error). Matches Ecto's `:length` validation
  # metadata or a message mentioning the value being too long.
  defp has_truncation_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {msg, opts}} ->
      Keyword.get(opts, :validation) == :length or
        Keyword.has_key?(opts, :count) or
        String.contains?(msg, "too long") or
        String.contains?(msg, "should be at most")
    end)
  end

  defp has_library_type_mismatch?(changeset) do
    Enum.any?(changeset.errors, fn
      {field, {msg, _opts}} when field in [:media_item_id, :episode_id] ->
        String.contains?(msg, "library type")

      _ ->
        false
    end)
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp format_changeset_errors(other), do: format_error(other)

  defp format_error(:not_found), do: "Directory not found"
  defp format_error(:not_directory), do: "Path is not a directory"
  defp format_error(:permission_denied), do: "Permission denied"
  defp format_error(reason), do: inspect(reason)

  # Validation functions for form data
  defp validate_edit_form(params) do
    types = %{
      title: :string,
      provider_id: :string,
      season: :integer,
      episodes: {:array, :integer},
      type: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, [:title, :provider_id, :season, :type])
    |> cast_episode_list(params["episodes"])
    |> Ecto.Changeset.validate_required([:title, :type])
    |> normalize_media_type()
  end

  defp validate_search_result(params) do
    types = %{
      provider_id: :string,
      title: :string,
      year: :string,
      type: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, [:provider_id, :title, :year, :type])
    |> Ecto.Changeset.validate_required([:provider_id, :title, :type])
    |> normalize_media_type()
  end

  defp cast_episode_list(changeset, episodes_param) when is_binary(episodes_param) do
    case parse_episode_list(episodes_param) do
      {:ok, episodes} ->
        Ecto.Changeset.put_change(changeset, :episodes, episodes)

      {:error, _message} ->
        Ecto.Changeset.add_error(changeset, :episodes, "invalid episode format")
    end
  end

  defp cast_episode_list(changeset, _), do: changeset

  defp normalize_media_type(changeset) do
    case Ecto.Changeset.get_change(changeset, :type) do
      "tv" ->
        Ecto.Changeset.put_change(changeset, :type, :tv_show)

      "movie" ->
        Ecto.Changeset.put_change(changeset, :type, :movie)

      type when is_binary(type) ->
        case String.to_existing_atom(type) do
          atom when atom in [:tv_show, :movie] ->
            Ecto.Changeset.put_change(changeset, :type, atom)

          _ ->
            Ecto.Changeset.add_error(changeset, :type, "invalid media type")
        end

      _ ->
        changeset
    end
  rescue
    ArgumentError ->
      Ecto.Changeset.add_error(changeset, :type, "invalid media type")
  end

  # Parse helper functions for edit form
  defp parse_episode_list(""), do: {:ok, []}

  defp parse_episode_list(value) when is_binary(value) do
    episodes =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn ep_str ->
        case Integer.parse(ep_str) do
          {int, ""} -> {:ok, int}
          _ -> {:error, ep_str}
        end
      end)

    errors = Enum.filter(episodes, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(episodes, fn {:ok, ep} -> ep end)}
    else
      {:error, "Invalid episode number format"}
    end
  end

  defp parse_episode_list(value) when is_list(value), do: {:ok, value}

  defp parse_inline_field("season", value), do: parse_season_value(value)
  defp parse_inline_field("episodes", value), do: parse_episode_list(value)
  defp parse_inline_field(_, _), do: :error

  defp parse_season_value(""), do: {:ok, nil}

  defp parse_season_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  # Calculates the relative path and library_path_id for an absolute file path
  # Returns {library_path_id, relative_path}
  defp calculate_relative_path_for_import(absolute_path, library_paths) do
    # Find the library_path that this file belongs to (longest matching prefix)
    matching_path =
      library_paths
      |> Enum.filter(fn lp -> String.starts_with?(absolute_path, lp.path) end)
      |> Enum.max_by(fn lp -> String.length(lp.path) end, fn -> nil end)

    case matching_path do
      nil ->
        Logger.warning("No matching library path found for file during import",
          path: absolute_path
        )

        # Return nil for both - the changeset will handle validation
        {nil, nil}

      library_path ->
        # Calculate relative path by removing the library path prefix
        relative_path =
          absolute_path
          |> String.replace_prefix(library_path.path, "")
          |> String.trim_leading("/")

        {library_path.id, relative_path}
    end
  end
end
