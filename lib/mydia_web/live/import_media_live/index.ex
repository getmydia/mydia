defmodule MydiaWeb.ImportMediaLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.{Library, Metadata, Settings}
  alias Mydia.Library.{Scanner, MetadataMatcher, FileGrouper}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import Media")
     |> assign(:step, :select_path)
     |> assign(:scan_path, "")
     |> assign(:scanning, false)
     |> assign(:matching, false)
     |> assign(:importing, false)
     |> assign(:discovered_files, [])
     |> assign(:matched_files, [])
     |> assign(:grouped_files, %{series: [], movies: [], ungrouped: []})
     |> assign(:selected_files, MapSet.new())
     |> assign(:scan_stats, %{total: 0, matched: 0, unmatched: 0, skipped: 0, orphaned: 0})
     |> assign(:library_paths, Settings.list_library_paths())
     |> assign(:metadata_config, Metadata.default_relay_config())
     |> assign(:import_progress, %{current: 0, total: 0, current_file: nil})
     |> assign(:import_results, %{success: 0, failed: 0, skipped: 0})
     |> assign(:detailed_results, [])
     |> assign(:editing_file_index, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:path_suggestions, [])
     |> assign(:show_path_suggestions, false)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Event Handlers

  @impl true
  def handle_event("update_path", %{"value" => path}, socket) do
    {:noreply, assign(socket, :scan_path, path)}
  end

  def handle_event("autocomplete_path", %{"path" => path}, socket) do
    suggestions = suggest_directories(path)

    {:noreply,
     socket
     |> assign(:scan_path, path)
     |> assign(:path_suggestions, suggestions)
     |> assign(:show_path_suggestions, suggestions != [])}
  end

  def handle_event("select_path_suggestion", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:scan_path, path)
     |> assign(:show_path_suggestions, false)
     |> assign(:path_suggestions, [])}
  end

  def handle_event("hide_path_suggestions", _params, socket) do
    {:noreply, assign(socket, :show_path_suggestions, false)}
  end

  def handle_event("select_library_path", %{"path_id" => path_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      library_path = Enum.find(socket.assigns.library_paths, &(to_string(&1.id) == path_id))

      if library_path do
        # Automatically start scan when library path is selected
        send(self(), {:perform_scan, library_path.path})

        {:noreply,
         socket
         |> assign(:scan_path, library_path.path)
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

  def handle_event("start_scan", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      if String.trim(socket.assigns.scan_path) != "" do
        send(self(), {:perform_scan, socket.assigns.scan_path})

        {:noreply,
         socket
         |> assign(:scanning, true)
         |> assign(:step, :review)
         |> assign(:discovered_files, [])
         |> assign(:matched_files, [])}
      else
        {:noreply, put_flash(socket, :error, "Please enter a path to scan")}
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

    {:noreply, assign(socket, :selected_files, selected_files)}
  end

  def handle_event("select_all_files", _params, socket) do
    # Select only successfully matched files
    matched_indices =
      socket.assigns.matched_files
      |> Enum.with_index()
      |> Enum.filter(fn {file, _idx} -> file.match_result != nil end)
      |> Enum.map(fn {_file, idx} -> idx end)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_files, matched_indices)}
  end

  def handle_event("deselect_all_files", _params, socket) do
    {:noreply, assign(socket, :selected_files, MapSet.new())}
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

    {:noreply, assign(socket, :selected_files, selected_files)}
  end

  def handle_event("start_import", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      if MapSet.size(socket.assigns.selected_files) > 0 do
        send(self(), :perform_import)

        {:noreply,
         socket
         |> assign(:importing, true)
         |> assign(:step, :importing)
         |> assign(
           :import_progress,
           %{current: 0, total: MapSet.size(socket.assigns.selected_files), current_file: nil}
         )}
      else
        {:noreply, put_flash(socket, :error, "Please select at least one file to import")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("start_over", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :select_path)
     |> assign(:scan_path, "")
     |> assign(:discovered_files, [])
     |> assign(:matched_files, [])
     |> assign(:selected_files, MapSet.new())
     |> assign(:import_results, %{success: 0, failed: 0, skipped: 0})
     |> assign(:detailed_results, [])}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/media")}
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
            "year" => to_string(match.year || ""),
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
            "year" => "",
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
       |> assign(:search_results, [])}
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
              year: validated_data.year,
              manually_edited: true,
              parsed_info:
                Map.merge(matched_file.match_result.parsed_info, %{
                  season: validated_data.season,
                  episodes: validated_data.episodes,
                  type: validated_data.type
                })
            })
          else
            # Create new match for previously unmatched file
            %{
              title: validated_data.title,
              provider_id: validated_data.provider_id,
              year: validated_data.year,
              match_confidence: 1.0,
              manually_edited: true,
              metadata: %{},
              parsed_info: %{
                season: validated_data.season,
                episodes: validated_data.episodes,
                type: validated_data.type
              }
            }
          end

        # Update the matched_file in the list
        updated_matched_file = %{matched_file | match_result: updated_match}

        updated_matched_files =
          List.replace_at(socket.assigns.matched_files, index, updated_matched_file)

        # Re-group files to update the hierarchical view
        grouped_files = FileGrouper.group_files(updated_matched_files)

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

        {:noreply,
         socket
         |> assign(:matched_files, updated_matched_files)
         |> assign(:grouped_files, grouped_files)
         |> assign(:scan_stats, scan_stats)
         |> assign(:editing_file_index, nil)
         |> assign(:edit_form, nil)
         |> assign(:search_query, "")
         |> assign(:search_results, [])
         |> put_flash(:info, flash_message)}
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
        |> Map.put("year", validated_data.year)
        |> Map.put("type", validated_data.type)

      {:noreply,
       socket
       |> assign(:edit_form, updated_form)
       |> assign(:search_results, [])
       |> assign(:search_query, validated_data.title)}
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
      grouped_files = FileGrouper.group_files(updated_matched_files)

      # Remove from selected files if it was selected
      selected_files = MapSet.delete(socket.assigns.selected_files, index)

      {:noreply,
       socket
       |> assign(:matched_files, updated_matched_files)
       |> assign(:grouped_files, grouped_files)
       |> assign(:selected_files, selected_files)
       |> put_flash(:info, "Match cleared")}
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

  ## Private Helpers

  defp perform_search(query, socket) do
    if String.trim(query) != "" && String.length(query) >= 2 do
      # Search both movies and TV shows
      config = socket.assigns.metadata_config

      movie_results =
        case Metadata.search(config, query, media_type: :movie) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "movie"))
          _ -> []
        end

      tv_results =
        case Metadata.search(config, query, media_type: :tv_show) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "tv"))
          _ -> []
        end

      # Combine and limit to first 10 results
      search_results = (movie_results ++ tv_results) |> Enum.take(10)

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

  ## Async Handlers

  @impl true
  def handle_info({:perform_scan, path}, socket) do
    case Scanner.scan(path) do
      {:ok, scan_result} ->
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

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:scanning, false)
         |> assign(:step, :select_path)
         |> put_flash(:error, "Scan failed: #{format_error(reason)}")}
    end
  end

  def handle_info({:match_files, files}, socket) do
    # Match files with TMDB in batches for better UX
    matched_files =
      Enum.map(files, fn file ->
        match_result =
          case MetadataMatcher.match_file(file.path, config: socket.assigns.metadata_config) do
            {:ok, match} -> match
            {:error, _reason} -> nil
          end

        %{
          file: file,
          match_result: match_result,
          import_status: :pending
        }
      end)

    # Calculate stats
    matched_count = Enum.count(matched_files, &(&1.match_result != nil))
    unmatched_count = length(matched_files) - matched_count

    # Group files hierarchically
    grouped_files = FileGrouper.group_files(matched_files)

    # Auto-select files with high confidence matches
    auto_selected =
      matched_files
      |> Enum.with_index()
      |> Enum.filter(fn {file, _idx} ->
        file.match_result != nil && file.match_result.match_confidence >= 0.8
      end)
      |> Enum.map(fn {_file, idx} -> idx end)
      |> MapSet.new()

    {:noreply,
     socket
     |> assign(:matching, false)
     |> assign(:step, :review)
     |> assign(:matched_files, matched_files)
     |> assign(:grouped_files, grouped_files)
     |> assign(:selected_files, auto_selected)
     |> assign(:scan_stats, %{
       total: length(files),
       matched: matched_count,
       unmatched: unmatched_count,
       skipped: socket.assigns.scan_stats.skipped
     })}
  end

  def handle_info(:perform_import, socket) do
    selected_indices = MapSet.to_list(socket.assigns.selected_files)
    selected_files = Enum.map(selected_indices, &Enum.at(socket.assigns.matched_files, &1))

    # Import each file and collect detailed results
    detailed_results =
      Enum.with_index(selected_files)
      |> Enum.map(fn {matched_file, idx} ->
        # Update progress with current file
        file_name = Path.basename(matched_file.file.path)
        send(self(), {:update_import_progress, idx + 1, file_name})

        import_file_with_details(matched_file, socket.assigns.metadata_config)
      end)

    success_count = Enum.count(detailed_results, &(&1.status == :success))
    failed_count = Enum.count(detailed_results, &(&1.status == :failed))
    skipped_count = Enum.count(detailed_results, &(&1.status == :skipped))

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:step, :complete)
     |> assign(:import_results, %{
       success: success_count,
       failed: failed_count,
       skipped: skipped_count
     })
     |> assign(:detailed_results, detailed_results)}
  end

  def handle_info({:update_import_progress, current, current_file}, socket) do
    {:noreply,
     assign(socket, :import_progress, %{
       socket.assigns.import_progress
       | current: current,
         current_file: current_file
     })}
  end

  ## Private Helpers

  defp import_file_with_details(%{match_result: nil, file: file}, _config) do
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
        error_msg =
          case changeset do
            %Ecto.Changeset{errors: errors} ->
              errors
              |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
              |> Enum.join(", ")

            other ->
              format_error(other)
          end

        %{
          file_path: file.path,
          file_name: Path.basename(file.path),
          status: :failed,
          media_item_title: match_result.title,
          error_message: "Database error: #{error_msg}",
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
        error_message: "Unexpected error: #{Exception.message(error)}",
        action_taken: nil,
        metadata: %{size: file.size}
      }
  end

  defp build_success_message(match_result, is_orphaned) do
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

    action =
      if is_orphaned do
        "Re-matched orphaned file as #{media_type}"
      else
        "Created #{media_type}"
      end

    "#{action}: '#{match_result.title}'"
  end

  defp format_error(:not_found), do: "Directory not found"
  defp format_error(:not_directory), do: "Path is not a directory"
  defp format_error(:permission_denied), do: "Permission denied"
  defp format_error(reason), do: inspect(reason)

  # Validation functions for form data
  defp validate_edit_form(params) do
    types = %{
      title: :string,
      provider_id: :string,
      year: :integer,
      season: :integer,
      episodes: {:array, :integer},
      type: :atom
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, [:title, :provider_id, :year, :season, :type])
    |> cast_episode_list(params["episodes"])
    |> Ecto.Changeset.validate_required([:title, :type])
    |> Ecto.Changeset.validate_inclusion(:type, [:movie, :tv_show])
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
  defp parse_optional_int(""), do: {:ok, nil}

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid number format"}
    end
  end

  defp parse_optional_int(value) when is_integer(value), do: {:ok, value}
  defp parse_optional_int(nil), do: {:ok, nil}

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

  defp normalize_media_type_string("tv"), do: "tv_show"
  defp normalize_media_type_string("movie"), do: "movie"
  defp normalize_media_type_string(type) when is_atom(type), do: to_string(type)
  defp normalize_media_type_string(type), do: type

  # Suggest directories based on partial path input
  defp suggest_directories(path) when is_binary(path) do
    # Only suggest if path is at least 2 characters
    if String.length(String.trim(path)) < 2 do
      []
    else
      # Determine the directory to list and the filter prefix
      {dir_to_list, filter_prefix} = parse_path_for_suggestions(path)

      case list_directories_safe(dir_to_list) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn entry ->
            String.starts_with?(entry, filter_prefix)
          end)
          |> Enum.take(10)
          |> Enum.map(fn entry ->
            Path.join(dir_to_list, entry)
          end)

        {:error, _reason} ->
          []
      end
    end
  end

  # Parse the path to determine which directory to list and what to filter by
  defp parse_path_for_suggestions(path) do
    path = String.trim(path)

    cond do
      # If path ends with /, list that directory
      String.ends_with?(path, "/") ->
        {path, ""}

      # If path contains /, split into directory and prefix
      String.contains?(path, "/") ->
        dir = Path.dirname(path)
        basename = Path.basename(path)
        {dir, basename}

      # Otherwise, list root and filter by the entire path
      true ->
        {"/", path}
    end
  end

  # Safely list directories with error handling
  defp list_directories_safe(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        # Filter to only include directories
        directories =
          entries
          |> Enum.filter(fn entry ->
            full_path = Path.join(dir, entry)
            File.dir?(full_path)
          end)
          |> Enum.sort()

        {:ok, directories}

      {:error, reason} ->
        {:error, reason}
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
        require Logger

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
