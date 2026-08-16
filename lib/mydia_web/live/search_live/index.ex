defmodule MydiaWeb.SearchLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.CategoryMapping
  alias Mydia.Library.ReleaseParser, as: FileParser
  alias Mydia.Metadata
  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Settings

  import MydiaWeb.IndexerComponents

  alias Mydia.Indexers.Structs.IndexerProgress

  require Logger

  # Library type options for the filter
  @library_type_options [
    {:all, "All Types"},
    {:movies, "Movies"},
    {:series, "TV Series"},
    {:music, "Music"},
    {:books, "Books"},
    {:adult, "Adult"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    # Load available indexers (both traditional and Cardigann)
    traditional_indexers =
      Settings.list_indexer_configs()
      |> Enum.filter(& &1.enabled)
      |> Enum.map(fn indexer ->
        %{id: indexer.id, name: indexer.name, type: indexer.type, source: :traditional}
      end)

    cardigann_indexers =
      if Indexers.CardigannFeatureFlags.enabled?() do
        Indexers.list_cardigann_definitions(enabled: true)
        |> Enum.map(fn def ->
          %{id: def.id, name: def.name, type: :cardigann, source: :cardigann}
        end)
      else
        []
      end

    available_indexers = traditional_indexers ++ cardigann_indexers

    # By default, select all enabled indexers
    selected_indexer_ids =
      available_indexers
      |> Enum.map(& &1.id)
      |> MapSet.new()

    # Load library paths for download target selector (exclude disabled paths)
    library_paths = Settings.list_library_paths() |> Enum.reject(& &1.disabled)

    {:ok,
     socket
     |> assign(:page_title, "Search Media")
     |> assign(:search_query, "")
     |> assign(:searching, false)
     |> assign(:min_seeders, 0)
     |> assign(:max_size_gb, nil)
     |> assign(:min_size_gb, nil)
     |> assign(:quality_filter, nil)
     |> assign(:library_type_filter, :all)
     |> assign(:library_type_options, @library_type_options)
     |> assign(:sort_by, :quality)
     |> assign(:results_empty?, false)
     |> assign(:indexer_errors, [])
     |> assign(:indexer_progress, %{})
     |> assign(:search_id, 0)
     |> assign(:show_disambiguation_modal, false)
     |> assign(:metadata_matches, [])
     |> assign(:metadata_media_type, nil)
     |> assign(:pending_parsed, nil)
     |> assign(:pending_release_title, nil)
     |> assign(:pending_search_result, nil)
     |> assign(:should_download_after_add, false)
     |> assign(:show_manual_search_modal, false)
     |> assign(:manual_search_query, "")
     |> assign(:failed_release_title, nil)
     |> assign(:selecting_match_id, nil)
     |> assign(:show_retry_modal, false)
     |> assign(:retry_error_message, nil)
     |> assign(:search_results_map, %{})
     |> assign(:raw_search_results_map, %{})
     |> assign(:show_detail_modal, false)
     |> assign(:selected_result, nil)
     |> assign(:show_download_modal, false)
     |> assign(:download_modal_result, nil)
     |> assign(:download_target_type, nil)
     |> assign(:confirming_download, false)
     |> assign(:downloading_urls, MapSet.new())
     |> assign(:library_paths, library_paths)
     |> assign(:available_indexers, available_indexers)
     |> assign(:selected_indexer_ids, selected_indexer_ids)
     |> stream_configure(:search_results, dom_id: &generate_result_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      case params do
        %{"q" => query} when is_binary(query) and query != "" ->
          start_search(socket, query)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:results_empty?, false)
       |> stream(:search_results, [], reset: true)}
    else
      {:noreply, push_patch(socket, to: ~p"/search?#{[q: query]}")}
    end
  end

  def handle_event("filter", params, socket) do
    # Parse filter params
    min_seeders =
      case params["min_seeders"] do
        "" -> 0
        val when is_binary(val) -> String.to_integer(val)
        _ -> 0
      end

    quality_filter =
      case params["quality"] do
        "" -> nil
        q when q in ["720p", "1080p", "2160p", "4k"] -> q
        _ -> nil
      end

    library_type_filter =
      case params["library_type"] do
        "" ->
          :all

        "all" ->
          :all

        type when type in ["movies", "series", "music", "books", "adult"] ->
          String.to_existing_atom(type)

        _ ->
          socket.assigns.library_type_filter
      end

    min_size_gb =
      case params["min_size"] do
        "" -> nil
        val when is_binary(val) -> parse_float(val)
        _ -> nil
      end

    max_size_gb =
      case params["max_size"] do
        "" -> nil
        val when is_binary(val) -> parse_float(val)
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:min_seeders, min_seeders)
     |> assign(:quality_filter, quality_filter)
     |> assign(:library_type_filter, library_type_filter)
     |> assign(:min_size_gb, min_size_gb)
     |> assign(:max_size_gb, max_size_gb)
     |> apply_filters()}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    sort_by = String.to_existing_atom(sort_by)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> apply_sort()}
  end

  def handle_event("toggle_indexer", %{"id" => indexer_id}, socket) do
    selected_ids = socket.assigns.selected_indexer_ids

    selected_ids =
      if MapSet.member?(selected_ids, indexer_id) do
        MapSet.delete(selected_ids, indexer_id)
      else
        MapSet.put(selected_ids, indexer_id)
      end

    {:noreply, assign(socket, :selected_indexer_ids, selected_ids)}
  end

  def handle_event("select_all_indexers", _params, socket) do
    all_ids =
      socket.assigns.available_indexers
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_indexer_ids, all_ids)}
  end

  def handle_event("deselect_all_indexers", _params, socket) do
    {:noreply, assign(socket, :selected_indexer_ids, MapSet.new())}
  end

  def handle_event("add_to_library", %{"title" => title} = params, socket) do
    # Store search result if provided for later use (for download)
    download_url = Map.get(params, "download_url")
    should_download = Map.get(params, "download", "false") == "true"

    # Find the full search result from our map
    search_result =
      if download_url do
        Map.get(socket.assigns.search_results_map, download_url)
      end

    if search_result do
      Logger.info(
        "Retrieved search_result from map, download_protocol: #{inspect(search_result.download_protocol)}"
      )
    end

    # Start async task to add media to library
    {:noreply,
     socket
     |> assign(:pending_release_title, title)
     |> assign(:pending_search_result, search_result)
     |> assign(:should_download_after_add, should_download)
     |> start_async(:add_to_library, fn -> add_release_to_library(title) end)}
  end

  def handle_event("select_metadata_match", %{"match_id" => match_id}, socket) do
    # Find the selected match
    selected_match =
      Enum.find(socket.assigns.metadata_matches, fn m -> to_string(m.provider_id) == match_id end)

    if selected_match do
      # Fetch full metadata and create media item
      media_type = socket.assigns.metadata_media_type
      parsed = socket.assigns.pending_parsed

      {:noreply,
       socket
       # Keep modal open but show loading state on selected match
       |> assign(:selecting_match_id, match_id)
       |> start_async(:finalize_add_to_library, fn ->
         config = Metadata.default_relay_config()

         case fetch_full_metadata(config, selected_match, media_type) do
           {:ok, metadata} ->
             create_media_item_from_metadata(parsed, metadata)

           error ->
             error
         end
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_disambiguation_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_disambiguation_modal, false)
     |> assign(:metadata_matches, [])
     |> assign(:pending_parsed, nil)}
  end

  def handle_event("manual_search_submit", %{"search_query" => query}, socket) do
    media_type = Map.get(socket.assigns, :manual_search_media_type, :movie)

    {:noreply,
     socket
     |> start_async(:manual_metadata_search, fn ->
       config = Metadata.default_relay_config()
       Metadata.search(config, query, media_type: media_type)
     end)}
  end

  def handle_event("close_manual_search_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_manual_search_modal, false)
     |> assign(:failed_release_title, nil)
     |> assign(:manual_search_query, "")}
  end

  def handle_event(
        "select_manual_match",
        %{"match_id" => match_id, "media_type" => media_type},
        socket
      ) do
    # Find the selected match from manual search
    selected_match =
      Enum.find(socket.assigns.metadata_matches, fn m -> to_string(m.provider_id) == match_id end)

    if selected_match do
      media_type_atom = String.to_existing_atom(media_type)

      {:noreply,
       socket
       # Keep modal open but show loading state on selected match
       |> assign(:selecting_match_id, match_id)
       |> start_async(:finalize_manual_add, fn ->
         config = Metadata.default_relay_config()

         case fetch_full_metadata(config, selected_match, media_type_atom) do
           {:ok, metadata} ->
             # Create media item without parsed data (since parsing failed)
             # Episodes are automatically fetched for TV shows via create_media_item
             attrs = build_media_item_attrs_from_metadata_only(metadata, media_type_atom)
             Media.create_media_item(attrs)

           error ->
             error
         end
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_add_to_library", _params, socket) do
    # Retry adding to library with the same parameters
    release_title = socket.assigns.pending_release_title

    if release_title do
      Logger.info("Retrying add to library for: #{release_title}")

      {:noreply,
       socket
       |> assign(:show_retry_modal, false)
       |> start_async(:add_to_library, fn -> add_release_to_library(release_title) end)}
    else
      {:noreply,
       socket
       |> assign(:show_retry_modal, false)
       |> put_flash(:error, "Cannot retry: missing release information")}
    end
  end

  def handle_event("close_retry_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_retry_modal, false)
     |> assign(:retry_error_message, nil)}
  end

  def handle_event("show_download_modal", %{"download_url" => download_url}, socket) do
    # Find the search result by download URL
    search_result = Map.get(socket.assigns.search_results_map, download_url)

    # Detect the library type from category - nil if unknown
    detected_type =
      if search_result && is_integer(search_result.category) do
        type = CategoryMapping.type_for_category(search_result.category)
        # Return nil for :other so user must select
        if type == :other, do: nil, else: type
      else
        # No category detected - require manual selection
        nil
      end

    # If type is detected, skip the modal and proceed directly to download
    if detected_type do
      Logger.info(
        "Auto-detected type #{detected_type}, skipping modal for: #{search_result.title}"
      )

      # Track this URL as downloading (for loading indicator)
      downloading_urls = MapSet.put(socket.assigns.downloading_urls, download_url)

      socket =
        socket
        |> assign(:show_detail_modal, false)
        |> assign(:selected_result, nil)
        |> assign(:download_modal_result, search_result)
        |> assign(:download_target_type, detected_type)
        |> assign(:confirming_download, true)
        |> assign(:downloading_urls, downloading_urls)
        |> assign(:pending_release_title, search_result.title)
        |> assign(:pending_search_result, search_result)
        |> assign(:should_download_after_add, true)
        # Re-insert result into stream to trigger UI update for loading state
        |> stream_insert(:search_results, search_result)

      # Use appropriate download flow based on type
      socket =
        if detected_type in [:movies, :series] do
          start_async(socket, :add_to_library, fn ->
            add_release_to_library(search_result.title)
          end)
        else
          start_async(socket, :direct_download, fn ->
            direct_download_to_library(search_result, detected_type)
          end)
        end

      {:noreply, socket}
    else
      {:noreply,
       socket
       # Close detail modal if it's open
       |> assign(:show_detail_modal, false)
       |> assign(:selected_result, nil)
       # Open download modal
       |> assign(:show_download_modal, true)
       |> assign(:download_modal_result, search_result)
       |> assign(:download_target_type, detected_type)}
    end
  end

  def handle_event("close_download_modal", _params, socket) do
    {:noreply, close_download_modal(socket)}
  end

  def handle_event("set_download_target_type", %{"type" => type}, socket) do
    target_type = String.to_existing_atom(type)

    {:noreply, assign(socket, :download_target_type, target_type)}
  end

  def handle_event("confirm_download", _params, socket) do
    search_result = socket.assigns.download_modal_result
    target_type = socket.assigns.download_target_type

    if search_result do
      Logger.info("Confirming download for: #{search_result.title}, target type: #{target_type}")

      # Track this URL as downloading and set loading state
      downloading_urls = MapSet.put(socket.assigns.downloading_urls, search_result.download_url)

      socket =
        socket
        |> assign(:confirming_download, true)
        |> assign(:downloading_urls, downloading_urls)
        # Re-insert result into stream to trigger UI update for loading state
        |> stream_insert(:search_results, search_result)

      # Use the target type to determine the download flow
      case target_type do
        type when type in [:music, :books, :adult] ->
          # For specialized libraries, download directly without metadata lookup
          {:noreply,
           socket
           |> assign(:pending_release_title, search_result.title)
           |> assign(:pending_search_result, search_result)
           |> assign(:should_download_after_add, true)
           |> start_async(:direct_download, fn ->
             direct_download_to_library(search_result, type)
           end)}

        type when type in [:movies, :series] ->
          # For movies/series, use the existing metadata lookup flow
          {:noreply,
           socket
           |> assign(:pending_release_title, search_result.title)
           |> assign(:pending_search_result, search_result)
           |> assign(:should_download_after_add, true)
           |> start_async(:add_to_library, fn ->
             add_release_to_library(search_result.title)
           end)}

        _ ->
          {:noreply,
           close_download_modal(put_flash(socket, :error, "Unknown library type: #{target_type}"))}
      end
    else
      {:noreply, close_download_modal(put_flash(socket, :error, "No search result selected"))}
    end
  end

  def handle_event("show_detail", %{"download_url" => download_url}, socket) do
    # Find the search result by download URL
    selected_result = Map.get(socket.assigns.search_results_map, download_url)

    {:noreply,
     socket
     |> assign(:show_detail_modal, true)
     |> assign(:selected_result, selected_result)}
  end

  def handle_event("close_detail_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_detail_modal, false)
     |> assign(:selected_result, nil)}
  end

  def handle_event("retry_indexer", %{"id" => indexer_id}, socket) do
    query = socket.assigns.search_query
    min_seeders = socket.assigns.min_seeders
    lv = self()
    search_id = socket.assigns.search_id

    # Map.replace_lazy/3 no-ops when indexer_id isn't a key in the map, rather
    # than inserting `indexer_id => nil` (as Map.update/4's default would),
    # which would otherwise flow a nil straight into the status chip
    # component. Not reachable through the shipped UI today (the Retry
    # button only renders for rows already present in the map), but an
    # unknown or forged id should be a clean no-op, not a crash landmine.
    indexer_progress =
      Map.replace_lazy(socket.assigns.indexer_progress, indexer_id, fn entry ->
        %{entry | status: :pending, error: nil, result_count: nil, duration_ms: nil}
      end)

    {:noreply,
     socket
     |> assign(:indexer_progress, indexer_progress)
     # A distinct key so a retry never cancels an in-flight full search.
     |> start_async({:retry, indexer_id}, fn ->
       perform_search(query, min_seeders, [indexer_id], lv, search_id)
     end)}
  end

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Just trigger a re-render to update the downloads counter in the sidebar
    # The counter will be recalculated when the layout renders
    {:noreply, socket}
  end

  def handle_info({:trigger_download, search_result, media_item_id, title}, socket) do
    # This will be called after adding to library if download was requested
    Logger.info("Initiating download for: #{title}")

    case Downloads.initiate_download(search_result, media_item_id: media_item_id) do
      {:ok, download} ->
        Logger.info("Download initiated successfully: #{download.title}")

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{title} added to library and download started. View in Downloads queue."
         )}

      {:error, :duplicate_download} ->
        Logger.info("Skipping download - already exists")

        {:noreply,
         socket
         |> put_flash(:info, "#{title} added to library. Download already in progress.")}

      {:error, :already_have_files} ->
        Logger.info("Skipping download - media files already exist")

        {:noreply,
         socket
         |> put_flash(:info, "#{title} added to library. You already have these files.")}

      {:error, :no_clients_configured} ->
        Logger.warning("Cannot initiate download - no download clients configured")

        {:noreply,
         socket
         |> put_flash(
           :warning,
           "#{title} added to library, but no download clients are configured. Please configure a download client in settings."
         )}

      {:error, {:client_not_found, client_name}} ->
        Logger.error("Download client not found: #{client_name}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{title} added to library, but download client '#{client_name}' not found."
         )}

      {:error, {:client_error, error}} ->
        Logger.error("Download client error: #{inspect(error)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{title} added to library, but download failed: #{format_client_error(error)}"
         )}

      {:error, reason} ->
        Logger.error("Failed to initiate download: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{title} added to library, but download failed: #{inspect(reason)}"
         )}
    end
  end

  # Grab outcomes are broadcast on the "downloads" topic and handled by
  # MediaLive.Show, which owns the manual-search UI. Ignore them quietly here
  # so the catch-all below keeps meaning "genuinely unexpected message".
  def handle_info({:grab_completed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_failed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_duplicate, _payload}, socket), do: {:noreply, socket}

  def handle_info({:indexer_search_started, search_id, pending}, socket) do
    if search_id == socket.assigns.search_id do
      incoming = Map.new(pending, fn entry -> {entry.indexer_id, entry} end)

      # Merge rather than replace: a scoped retry's on_start message only
      # covers the indexer(s) actually being retried, so a full replace here
      # would wipe every OTHER indexer's chip (success counts, durations,
      # errors) out of indexer_progress, even though those indexers were
      # never re-searched and will never report in again this search. A
      # fresh search still resets indexer_progress to %{} before starting
      # (see start_search/2), so merge and replace are equivalent there;
      # this only changes behavior for the scoped-retry case.
      progress = Map.merge(socket.assigns.indexer_progress, incoming)
      {:noreply, assign(socket, :indexer_progress, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:indexer_progress, search_id, %IndexerProgress{} = progress}, socket) do
    if search_id == socket.assigns.search_id do
      {:noreply, apply_indexer_progress(socket, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    # Catch-all for unhandled messages to prevent crashes
    Logger.warning("Unhandled message in SearchLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, results, indexer_errors}}, socket) do
    start_time = System.monotonic_time(:millisecond)

    filtered_results = filter_results(results, socket.assigns)
    sorted_results = sort_results(filtered_results, socket.assigns.sort_by)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Search completed: query=\"#{socket.assigns.search_query}\", " <>
        "results=#{length(results)}, filtered=#{length(filtered_results)}, " <>
        "indexer_errors=#{length(indexer_errors)}, processing_time=#{duration}ms"
    )

    # Store results in a map for quick lookup by download_url
    results_map =
      results
      |> Enum.map(fn result ->
        Logger.info(
          "Storing result in map: #{result.title}, protocol: #{inspect(result.download_protocol)}"
        )

        {result.download_url, result}
      end)
      |> Map.new()

    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:results_empty?, sorted_results == [])
     |> assign(:indexer_errors, indexer_errors)
     |> assign(:search_results_map, results_map)
     |> stream(:search_results, sorted_results, reset: true)}
  end

  def handle_async(:search, {:ok, {:error, reason}}, socket) do
    Logger.error("Search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, "Search failed: #{inspect(reason)}")}
  end

  def handle_async(:search, {:exit, reason}, socket) do
    Logger.error("Search task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, "Search failed unexpectedly")}
  end

  def handle_async({:retry, _indexer_id}, _result, socket) do
    # Results already arrived through the :indexer_progress messages; the final
    # batched value carries only this one indexer and would clobber the rest.
    {:noreply, socket}
  end

  def handle_async(
        :add_to_library,
        {:ok, {:ok, {:needs_disambiguation, parsed, matches, media_type}}},
        socket
      ) do
    Logger.info("Multiple metadata matches found, showing disambiguation modal")

    {:noreply,
     socket
     |> assign(:show_disambiguation_modal, true)
     |> assign(:metadata_matches, matches)
     |> assign(:metadata_media_type, media_type)
     |> assign(:pending_parsed, parsed)}
  end

  def handle_async(:add_to_library, {:ok, {:ok, media_item}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library")

    socket =
      socket
      |> close_download_modal()
      |> then(fn socket ->
        if socket.assigns.should_download_after_add && socket.assigns.pending_search_result do
          Logger.info("Triggering download for #{media_item.title}")
          # Trigger download - this will be handled by the download handler
          send(
            self(),
            {:trigger_download, socket.assigns.pending_search_result, media_item.id,
             media_item.title}
          )

          socket
        else
          put_flash(socket, :info, "#{media_item.title} added to library")
        end
      end)

    # Stay on search page so user can download more items
    {:noreply, socket}
  end

  def handle_async(:add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library: #{inspect(reason)}")

    # Close download modal first
    socket = close_download_modal(socket)

    case reason do
      :parse_failed ->
        # Show manual search modal for parse failures
        release_title = socket.assigns.pending_release_title || "Unknown"

        {:noreply,
         socket
         |> assign(:show_manual_search_modal, true)
         |> assign(:failed_release_title, release_title)
         |> assign(:manual_search_query, extract_search_hint(release_title))}

      :no_metadata_match ->
        # Also show manual search modal for no matches
        release_title = socket.assigns.pending_release_title || "Unknown"

        {:noreply,
         socket
         |> assign(:show_manual_search_modal, true)
         |> assign(:failed_release_title, release_title)
         |> assign(:manual_search_query, extract_search_hint(release_title))
         |> put_flash(:error, "Could not find matching media automatically")}

      {:metadata_error, msg} ->
        # Show retry modal for metadata errors
        {:noreply,
         socket
         |> assign(:show_retry_modal, true)
         |> assign(:retry_error_message, "Metadata provider error: #{msg}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to add to library: #{inspect(reason)}")}
    end
  end

  def handle_async(:add_to_library, {:exit, reason}, socket) do
    Logger.error("Add to library task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> close_download_modal()
     |> put_flash(:error, "Failed to add to library unexpectedly")}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:ok, media_item}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library after disambiguation")

    socket =
      socket
      |> assign(:show_disambiguation_modal, false)
      |> assign(:selecting_match_id, nil)
      |> close_download_modal()
      |> then(fn socket ->
        if socket.assigns.should_download_after_add && socket.assigns.pending_search_result do
          Logger.info("Triggering download for #{media_item.title}")

          send(
            self(),
            {:trigger_download, socket.assigns.pending_search_result, media_item.id,
             media_item.title}
          )

          socket
        else
          put_flash(socket, :info, "#{media_item.title} added to library")
        end
      end)

    # Stay on search page so user can download more items
    {:noreply, socket}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library after disambiguation: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> put_flash(:error, "Failed to add to library: #{inspect(reason)}")}
  end

  def handle_async(:finalize_add_to_library, {:exit, reason}, socket) do
    Logger.error("Finalize add to library task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> put_flash(:error, "Failed to add to library unexpectedly")}
  end

  def handle_async(:manual_metadata_search, {:ok, {:ok, results}}, socket) do
    Logger.info("Manual metadata search returned #{length(results)} results")

    {:noreply,
     socket
     |> assign(:metadata_matches, results)}
  end

  def handle_async(:manual_metadata_search, {:ok, {:error, reason}}, socket) do
    Logger.error("Manual metadata search failed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Search failed: #{inspect(reason)}")}
  end

  def handle_async(:finalize_manual_add, {:ok, {:ok, media_item}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library via manual search")

    # Stay on search page so user can download more items
    {:noreply,
     socket
     |> assign(:show_manual_search_modal, false)
     |> assign(:selecting_match_id, nil)
     |> close_download_modal()
     |> put_flash(:info, "#{media_item.title} added to library")}
  end

  def handle_async(:finalize_manual_add, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library via manual search: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:selecting_match_id, nil)
     |> put_flash(:error, "Failed to add to library: #{inspect(reason)}")}
  end

  # Handle direct download async results (for specialized libraries)
  def handle_async(:direct_download, {:ok, {:ok, download}}, socket) do
    Logger.info("Direct download started successfully: #{download.title}")

    # Stay on search page so user can download more items
    {:noreply,
     socket
     |> close_download_modal()
     |> put_flash(:info, "Download started: #{download.title}. View in Downloads queue.")}
  end

  def handle_async(:direct_download, {:ok, {:error, reason}}, socket) do
    Logger.error("Direct download failed: #{inspect(reason)}")

    error_msg =
      case reason do
        :no_library_path -> "No library path configured for this type"
        {:client_error, err} -> "Download client error: #{inspect(err)}"
        _ -> "Download failed: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> close_download_modal()
     |> put_flash(:error, error_msg)}
  end

  def handle_async(:direct_download, {:exit, reason}, socket) do
    Logger.error("Direct download task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> close_download_modal()
     |> put_flash(:error, "Download failed unexpectedly")}
  end

  ## Private Functions

  defp close_download_modal(socket) do
    # Clear the downloading URL if there was one and re-insert result to update UI
    {downloading_urls, socket} =
      if socket.assigns.pending_search_result do
        search_result = socket.assigns.pending_search_result
        urls = MapSet.delete(socket.assigns.downloading_urls, search_result.download_url)
        # Re-insert result into stream to trigger UI update (clear loading state)
        socket = stream_insert(socket, :search_results, search_result)
        {urls, socket}
      else
        {socket.assigns.downloading_urls, socket}
      end

    socket
    |> assign(:show_download_modal, false)
    |> assign(:download_modal_result, nil)
    |> assign(:download_target_type, nil)
    |> assign(:confirming_download, false)
    |> assign(:downloading_urls, downloading_urls)
  end

  defp generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  defp start_search(socket, query) do
    min_seeders = socket.assigns.min_seeders
    indexer_ids = MapSet.to_list(socket.assigns.selected_indexer_ids)
    # self() inside start_async is the task, not the LiveView, so capture it here.
    lv = self()
    search_id = socket.assigns.search_id + 1

    socket
    |> assign(:search_query, query)
    |> assign(:searching, true)
    |> assign(:search_id, search_id)
    |> assign(:indexer_progress, %{})
    |> assign(:indexer_errors, [])
    |> assign(:search_results_map, %{})
    |> assign(:raw_search_results_map, %{})
    |> assign(:results_empty?, false)
    |> stream(:search_results, [], reset: true)
    |> start_async(:search, fn ->
      perform_search(query, min_seeders, indexer_ids, lv, search_id)
    end)
  end

  defp perform_search(query, min_seeders, indexer_ids, lv, search_id) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true,
      indexer_ids: indexer_ids,
      on_start: fn pending -> send(lv, {:indexer_search_started, search_id, pending}) end,
      on_indexer_result: fn progress -> send(lv, {:indexer_progress, search_id, progress}) end
    ]

    case Indexers.search_all(query, opts) do
      {:ok, %{results: results, indexer_errors: indexer_errors}} ->
        {:ok, results, indexer_errors}

      other ->
        {:error, other}
    end
  end

  defp apply_filters(socket) do
    # Re-filter the current results without re-searching
    results = socket.assigns.search_results_map |> Map.values()
    filtered_results = filter_results(results, socket.assigns)
    sorted_results = sort_results(filtered_results, socket.assigns.sort_by)

    socket
    |> assign(:results_empty?, sorted_results == [])
    |> stream(:search_results, sorted_results, reset: true)
  end

  # Folds one indexer's results into the accumulated set and re-ranks the whole
  # thing, so the list stays correctly ordered as indexers report out of order.
  #
  # Two collections are kept deliberately, and must NOT be collapsed back into
  # one:
  #
  #   - raw_search_results_map: every release ever seen this search, keyed by
  #     download_url, UNTRUNCATED. This is what future progress messages fold
  #     new results onto.
  #   - search_results_map: the ranked-and-deduplicated (and therefore
  #     truncated-to-max_results) DISPLAY set, matching what handle_async
  #     assigns at the end of a search. apply_filters/1 re-filters straight
  #     from this map without deduplicating, so it must stay deduplicated.
  #
  # Plain truncation is NOT why the raw map exists: Indexers.rank_and_dedupe/3
  # scores each result independently of the rest of the pool, so an item's
  # rank can only stay the same or worsen as the pool grows. An item outside
  # round one's top max_results is outside the full-history top max_results
  # too, and folding onto a truncated base can never lose a genuine contender
  # to truncation alone.
  #
  # The real reason is DEDUPLICATION across rounds. An item can be evicted by
  # truncation while it was the sole member of its dedup group, having never
  # lost a dedup comparison. If a WEAKER duplicate of that same group arrives
  # in a later round, deduping against the truncated search_results_map would
  # see only the weak duplicate (the true winner already gone) and crown it
  # as the group's representative, showing the wrong release or dropping the
  # group when the true winner would have qualified. Re-ranking from the full
  # raw_search_results_map every round means deduplication always compares
  # every variant of a release ever seen, so the strongest one always wins.
  #
  # `results` is cleared from the stored progress struct: it can be large and
  # the releases already live in raw_search_results_map.
  defp apply_indexer_progress(socket, %IndexerProgress{} = progress) do
    indexer_progress =
      Map.put(socket.assigns.indexer_progress, progress.indexer_id, %{progress | results: []})

    raw_results =
      Enum.reduce(progress.results, socket.assigns.raw_search_results_map, fn result, acc ->
        Map.put(acc, result.download_url, result)
      end)

    ranked =
      raw_results
      |> Map.values()
      |> Indexers.rank_and_dedupe(socket.assigns.search_query,
        min_seeders: socket.assigns.min_seeders
      )

    results_map = Map.new(ranked, fn result -> {result.download_url, result} end)

    sorted =
      ranked
      |> filter_results(socket.assigns)
      |> sort_results(socket.assigns.sort_by)

    socket
    |> assign(:indexer_progress, indexer_progress)
    |> assign(:raw_search_results_map, raw_results)
    |> assign(:search_results_map, results_map)
    |> assign(:results_empty?, sorted == [])
    |> stream(:search_results, sorted, reset: true)
  end

  defp apply_sort(socket) do
    # Re-sort the current results
    results = socket.assigns.search_results_map |> Map.values()
    sorted_results = sort_results(results, socket.assigns.sort_by)

    socket
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp filter_results(results, assigns) do
    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
    |> filter_by_library_type(assigns.library_type_filter)
    |> filter_by_size(assigns.min_size_gb, assigns.max_size_gb)
  end

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    Enum.filter(results, fn result -> result.seeders >= min_seeders end)
  end

  defp filter_by_seeders(results, _), do: results

  defp filter_by_quality(results, nil), do: results

  defp filter_by_quality(results, quality_filter) do
    Enum.filter(results, fn result ->
      case result.quality do
        %{resolution: resolution} when not is_nil(resolution) ->
          # Normalize 2160p to 4k and vice versa
          normalized_resolution = normalize_resolution(resolution)
          normalized_filter = normalize_resolution(quality_filter)
          normalized_resolution == normalized_filter

        _ ->
          false
      end
    end)
  end

  defp filter_by_library_type(results, :all), do: results

  defp filter_by_library_type(results, library_type) do
    # Get the categories for this library type
    category_ids = CategoryMapping.categories_for_type(library_type)

    Enum.filter(results, fn result ->
      case result.category do
        nil -> false
        category_id when is_integer(category_id) -> category_id in category_ids
        _ -> false
      end
    end)
  end

  defp filter_by_size(results, nil, nil), do: results

  defp filter_by_size(results, min_gb, max_gb) do
    Enum.filter(results, fn result ->
      size_gb = result.size / (1024 * 1024 * 1024)

      min_ok = if min_gb, do: size_gb >= min_gb, else: true
      max_ok = if max_gb, do: size_gb <= max_gb, else: true

      min_ok && max_ok
    end)
  end

  defp normalize_resolution("2160p"), do: "4k"
  defp normalize_resolution("4k"), do: "4k"
  defp normalize_resolution(res), do: String.downcase(res)

  defp sort_results(results, :quality) do
    # Sort by quality score (already done by search_all), then by seeders
    results
    |> Enum.sort_by(fn result -> {quality_score(result), result.seeders} end, :desc)
  end

  defp sort_results(results, :seeders) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  defp sort_results(results, :size) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  defp sort_results(results, :date) do
    Enum.sort_by(
      results,
      fn result ->
        case result.published_at do
          nil -> DateTime.from_unix!(0)
          dt -> dt
        end
      end,
      {:desc, DateTime}
    )
  end

  defp quality_score(%SearchResult{quality: nil}), do: 0

  defp quality_score(%SearchResult{quality: quality}) do
    alias Mydia.Indexers.QualityParser
    QualityParser.quality_score(quality)
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> nil
    end
  end

  # Helper functions for the template

  defp get_quality_badges(%SearchResult{quality: nil}), do: []

  defp get_quality_badges(%SearchResult{quality: quality}) do
    badges = []

    # Resolution badge (primary - blue)
    badges =
      if quality.resolution do
        [%{text: quality.resolution, color: "badge-primary"} | badges]
      else
        badges
      end

    # Source badge (secondary - purple/gray)
    badges =
      if quality.source do
        [%{text: quality.source, color: "badge-secondary"} | badges]
      else
        badges
      end

    # Codec badge (accent - cyan)
    badges =
      if quality.codec do
        [%{text: quality.codec, color: "badge-accent"} | badges]
      else
        badges
      end

    # Audio badge (ghost - subtle)
    badges =
      if quality.audio do
        [%{text: quality.audio, color: "badge-ghost"} | badges]
      else
        badges
      end

    # Special indicators
    badges =
      if quality.hdr do
        [%{text: "HDR", color: "badge-warning"} | badges]
      else
        badges
      end

    badges =
      if quality.proper do
        [%{text: "PROPER", color: "badge-success"} | badges]
      else
        badges
      end

    badges =
      if quality.repack do
        [%{text: "REPACK", color: "badge-info"} | badges]
      else
        badges
      end

    Enum.reverse(badges)
  end

  defp get_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  defp format_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  defp health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end

  defp health_color(score) when score >= 0.7, do: "text-success"
  defp health_color(score) when score >= 0.4, do: "text-warning"
  defp health_color(_), do: "text-error"

  defp format_date(nil), do: "Unknown"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  # Indexer type helpers for the template
  defp indexer_type_badge_class(:prowlarr), do: "badge-primary"
  defp indexer_type_badge_class(:jackett), do: "badge-secondary"
  defp indexer_type_badge_class(:nzbhydra2), do: "badge-accent"
  defp indexer_type_badge_class(:public), do: "badge-ghost"
  defp indexer_type_badge_class(_), do: "badge-ghost"

  defp indexer_type_label(:prowlarr), do: "Prowlarr"
  defp indexer_type_label(:jackett), do: "Jackett"
  defp indexer_type_label(:nzbhydra2), do: "NZBHydra2"
  defp indexer_type_label(:public), do: "Public"
  defp indexer_type_label(type), do: to_string(type)

  ## Add to Library Functions

  defp add_release_to_library(title) do
    Logger.info("Adding release to library: #{title}")

    with {:ok, parsed} <- parse_release_title(title),
         {:ok, metadata_or_matches} <- search_and_fetch_metadata(parsed) do
      case metadata_or_matches do
        {:multiple_matches, matches, media_type} ->
          # Return the matches to trigger disambiguation in the UI
          {:ok, {:needs_disambiguation, parsed, matches, media_type}}

        metadata ->
          # Single match, create media item directly
          create_media_item_from_metadata(parsed, metadata)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp parse_release_title(title) do
    parsed = FileParser.parse(title)

    Logger.debug(
      "Parsed release: type=#{parsed.type}, title=#{parsed.title}, " <>
        "year=#{parsed.year}, season=#{parsed.season}, " <>
        "episodes=#{inspect(parsed.episodes)}, confidence=#{parsed.confidence}"
    )

    cond do
      parsed.type == :unknown ->
        {:error, :parse_failed}

      parsed.confidence < 0.5 ->
        Logger.warning("Low confidence parse (#{parsed.confidence}), may not be accurate")
        {:ok, parsed}

      true ->
        {:ok, parsed}
    end
  end

  defp search_and_fetch_metadata(parsed) do
    # Use the default metadata relay configuration
    config = Metadata.default_relay_config()

    # Determine media type for the search
    media_type =
      case parsed.type do
        :movie -> :movie
        :tv_show -> :tv_show
        _ -> :movie
      end

    # Search for the media
    search_opts = [media_type: media_type]
    search_opts = if parsed.year, do: [{:year, parsed.year} | search_opts], else: search_opts

    case Metadata.search(config, parsed.title, search_opts) do
      {:ok, []} ->
        Logger.warning("No metadata matches found for: #{parsed.title}")
        {:error, :no_metadata_match}

      {:ok, [single_match]} ->
        # Only one match, fetch it directly
        Logger.info(
          "Found single metadata match: #{single_match["title"] || single_match["name"]}"
        )

        fetch_full_metadata(config, single_match, media_type)

      {:ok, matches} when length(matches) > 1 ->
        # Multiple matches, return them for disambiguation
        Logger.info("Found #{length(matches)} metadata matches, requires disambiguation")
        {:ok, {:multiple_matches, matches, media_type}}

      {:error, reason} ->
        Logger.error("Metadata search failed: #{inspect(reason)}")
        {:error, {:metadata_error, "Search failed"}}
    end
  end

  defp fetch_full_metadata(config, match, media_type) do
    provider_id = match.provider_id

    case Metadata.fetch_by_id(config, to_string(provider_id), media_type: media_type) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, reason} ->
        Logger.error("Failed to fetch full metadata: #{inspect(reason)}")
        {:error, {:metadata_error, "Failed to fetch details"}}
    end
  end

  defp create_media_item_from_metadata(parsed, metadata) do
    # Check if media already exists by provider ID
    # For TV shows from TVDB, check tvdb_id; otherwise check tmdb_id
    existing =
      if parsed.type == :tv_show and Map.get(metadata, :provider) == :tvdb do
        Media.get_media_item_by_tvdb(metadata.provider_id)
      else
        Media.get_media_item_by_tmdb(metadata.provider_id)
      end

    case existing do
      nil ->
        # Create new media item
        attrs = build_media_item_attrs(parsed, metadata)

        # Episodes are automatically fetched for TV shows via create_media_item
        case Media.create_media_item(attrs) do
          {:ok, media_item} ->
            {:ok, media_item}

          {:error, changeset} ->
            Logger.error("Failed to create media item: #{inspect(changeset.errors)}")
            {:error, {:create_failed, changeset.errors}}
        end

      existing_item ->
        Logger.info("Media already exists in library: #{existing_item.title}")
        {:ok, existing_item}
    end
  end

  defp build_media_item_attrs(parsed, metadata) do
    type =
      case parsed.type do
        :movie -> "movie"
        :tv_show -> "tv_show"
        _ -> "movie"
      end

    # Get monitor_by_default setting from config
    config = Mydia.Config.get()
    monitor_by_default = config.media.monitor_by_default

    base = %{
      type: type,
      title: metadata.title || parsed.title,
      original_title: metadata.original_title,
      year:
        metadata.year ||
          (metadata.release_date && extract_year_from_date(metadata.release_date)) ||
          (metadata.first_air_date && extract_year_from_date(metadata.first_air_date)) ||
          parsed.year,
      metadata: metadata,
      monitored: monitor_by_default
    }

    # For TV shows from TVDB, store tvdb_id; otherwise store tmdb_id
    if parsed.type == :tv_show and Map.get(metadata, :provider) == :tvdb do
      Map.put(base, :tvdb_id, metadata.provider_id)
    else
      Map.put(base, :tmdb_id, metadata.provider_id)
    end
  end

  defp extract_year_from_date(%Date{} = date), do: date.year

  defp extract_year_from_date(date_string) when is_binary(date_string) do
    case String.split(date_string, "-") do
      [year_str | _] ->
        case Integer.parse(year_str) do
          {year, _} -> year
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_year_from_date(_), do: nil

  defp extract_search_hint(release_title) do
    # Try to extract a reasonable search query from the release title
    # Remove common release tags and patterns
    release_title
    |> String.replace(
      ~r/\b(720p|1080p|2160p|4k|WEB-?DL|BluRay|HDTV|x264|x265|HEVC|AAC|DTS)\b/i,
      ""
    )
    |> String.replace(~r/\b(S\d{1,2}E\d{1,2})\b/i, "")
    |> String.replace(~r/\b(\d{4})\b/, "")
    |> String.replace(~r/[\.\-_]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp build_media_item_attrs_from_metadata_only(metadata, media_type) do
    type =
      case media_type do
        :movie -> "movie"
        :tv_show -> "tv_show"
        _ -> "movie"
      end

    # Get monitor_by_default setting from config
    config = Mydia.Config.get()
    monitor_by_default = config.media.monitor_by_default

    base = %{
      type: type,
      title: metadata.title,
      original_title: metadata.original_title,
      year:
        metadata.year ||
          (metadata.release_date && extract_year_from_date(metadata.release_date)) ||
          (metadata.first_air_date && extract_year_from_date(metadata.first_air_date)),
      metadata: metadata,
      monitored: monitor_by_default
    }

    # For TV shows from TVDB, store tvdb_id; otherwise store tmdb_id
    if media_type == :tv_show and Map.get(metadata, :provider) == :tvdb do
      Map.put(base, :tvdb_id, metadata.provider_id)
    else
      Map.put(base, :tmdb_id, metadata.provider_id)
    end
  end

  defp format_client_error(error) when is_binary(error), do: error
  defp format_client_error(error), do: inspect(error)

  # Direct download for specialized libraries (music, books, adult)
  # These don't require metadata lookup - just start the download
  defp direct_download_to_library(search_result, library_type) do
    Logger.info("Starting direct download for #{library_type}: #{search_result.title}")

    # Find a library path for this type
    library_paths = Settings.list_library_paths()
    library_path = Enum.find(library_paths, fn path -> path.type == library_type end)

    if library_path do
      # Initiate the download with library_path_id instead of media_item_id
      Downloads.initiate_download(search_result, library_path_id: library_path.id)
    else
      Logger.warning("No library path found for type: #{library_type}")
      {:error, :no_library_path}
    end
  end

  # Helper to get library type label for display
  defp library_type_label(:movies), do: "Movies"
  defp library_type_label(:series), do: "TV Series"
  defp library_type_label(:music), do: "Music"
  defp library_type_label(:books), do: "Books"
  defp library_type_label(:adult), do: "Adult"
  defp library_type_label(:other), do: "Other"
  defp library_type_label(:unknown), do: "Select"
  defp library_type_label(_), do: "Unknown"

  # Helper to get library type icon
  defp library_type_icon(:movies), do: "hero-film"
  defp library_type_icon(:series), do: "hero-tv"
  defp library_type_icon(:music), do: "hero-musical-note"
  defp library_type_icon(:books), do: "hero-book-open"
  defp library_type_icon(:adult), do: "hero-eye-slash"
  defp library_type_icon(:unknown), do: "hero-question-mark-circle"
  defp library_type_icon(_), do: "hero-question-mark-circle"

  # Helper to get the detected library type for a search result
  # Returns {:ok, type} if detected, :unknown if category is nil/missing
  defp detected_library_type(%SearchResult{category: nil}), do: :unknown

  defp detected_library_type(%SearchResult{category: category}) when is_integer(category) do
    CategoryMapping.type_for_category(category)
  end

  defp detected_library_type(%SearchResult{category: category}) when is_binary(category) do
    # Try to parse string category to integer
    case Integer.parse(category) do
      {id, _} -> CategoryMapping.type_for_category(id)
      :error -> :unknown
    end
  end

  defp detected_library_type(_), do: :unknown

  # Badge color for library type
  defp library_type_badge_class(:movies), do: "badge-primary"
  defp library_type_badge_class(:series), do: "badge-secondary"
  defp library_type_badge_class(:music), do: "badge-accent"
  defp library_type_badge_class(:books), do: "badge-info"
  defp library_type_badge_class(:adult), do: "badge-warning"
  defp library_type_badge_class(:unknown), do: "badge-neutral"
  defp library_type_badge_class(_), do: "badge-ghost"
end
