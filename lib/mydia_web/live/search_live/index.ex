defmodule MydiaWeb.SearchLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.FileParser.V2, as: FileParser
  alias Mydia.Metadata
  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Jobs.{MovieSearch, TVShowSearch}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    {:ok,
     socket
     |> assign(:page_title, "Search Media")
     |> assign(:search_query, "")
     |> assign(:searching, false)
     |> assign(:min_seeders, 0)
     |> assign(:max_size_gb, nil)
     |> assign(:min_size_gb, nil)
     |> assign(:quality_filter, nil)
     |> assign(:sort_by, :quality)
     |> assign(:results_empty?, false)
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
     |> assign(:show_retry_modal, false)
     |> assign(:retry_error_message, nil)
     |> assign(:search_results_map, %{})
     |> assign(:show_detail_modal, false)
     |> assign(:selected_result, nil)
     |> stream_configure(:search_results, dom_id: &generate_result_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      case params do
        %{"q" => query} when is_binary(query) and query != "" ->
          # Trigger a search with the query parameter
          min_seeders = socket.assigns.min_seeders

          socket
          |> assign(:search_query, query)
          |> assign(:searching, true)
          |> start_async(:search, fn -> perform_search(query, min_seeders) end)

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
      # Extract only needed values to avoid copying the whole assigns to the async task
      min_seeders = socket.assigns.min_seeders

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:searching, true)
       |> start_async(:search, fn -> perform_search(query, min_seeders) end)}
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
       |> assign(:show_disambiguation_modal, false)
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
       |> assign(:show_manual_search_modal, false)
       |> start_async(:finalize_manual_add, fn ->
         config = Metadata.default_relay_config()

         case fetch_full_metadata(config, selected_match, media_type_atom) do
           {:ok, metadata} ->
             # Create media item without parsed data (since parsing failed)
             attrs = build_media_item_attrs_from_metadata_only(metadata, media_type_atom)

             case Media.create_media_item(attrs) do
               {:ok, media_item} ->
                 # For TV shows, always fetch all episodes
                 if media_type_atom == :tv_show do
                   Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all")
                 end

                 {:ok, media_item}

               error ->
                 error
             end

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

  @impl true
  def handle_async(:search, {:ok, {:ok, results}}, socket) do
    start_time = System.monotonic_time(:millisecond)

    filtered_results = filter_results(results, socket.assigns)
    sorted_results = sort_results(filtered_results, socket.assigns.sort_by)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Search completed: query=\"#{socket.assigns.search_query}\", " <>
        "results=#{length(results)}, filtered=#{length(filtered_results)}, " <>
        "processing_time=#{duration}ms"
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
      if socket.assigns.should_download_after_add && socket.assigns.pending_search_result do
        Logger.info("Triggering download for #{media_item.title}")
        # Trigger download - this will be handled by the download handler
        send(
          self(),
          {:trigger_download, socket.assigns.pending_search_result, media_item.id,
           media_item.title}
        )

        socket
        |> put_flash(:info, "#{media_item.title} added to library")
      else
        socket
        |> put_flash(:info, "#{media_item.title} added to library")
      end

    {:noreply,
     socket
     |> push_navigate(to: ~p"/media/#{media_item.id}")}
  end

  def handle_async(:add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library: #{inspect(reason)}")

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

    {:noreply, put_flash(socket, :error, "Failed to add to library unexpectedly")}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:ok, media_item}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library after disambiguation")

    socket =
      if socket.assigns.should_download_after_add && socket.assigns.pending_search_result do
        Logger.info("Triggering download for #{media_item.title}")

        send(
          self(),
          {:trigger_download, socket.assigns.pending_search_result, media_item.id,
           media_item.title}
        )

        socket
        |> put_flash(:info, "#{media_item.title} added to library")
      else
        socket
        |> put_flash(:info, "#{media_item.title} added to library")
      end

    {:noreply,
     socket
     |> push_navigate(to: ~p"/media/#{media_item.id}")}
  end

  def handle_async(:finalize_add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library after disambiguation: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Failed to add to library: #{inspect(reason)}")}
  end

  def handle_async(:finalize_add_to_library, {:exit, reason}, socket) do
    Logger.error("Finalize add to library task crashed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Failed to add to library unexpectedly")}
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

    {:noreply,
     socket
     |> put_flash(:info, "#{media_item.title} added to library")
     |> push_navigate(to: ~p"/media/#{media_item.id}")}
  end

  def handle_async(:finalize_manual_add, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library via manual search: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Failed to add to library: #{inspect(reason)}")}
  end

  ## Private Functions

  defp generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  defp perform_search(query, min_seeders) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true
    ]

    Indexers.search_all(query, opts)
  end

  defp apply_filters(socket) do
    # Re-filter the current results without re-searching
    results = socket.assigns.search_results |> Enum.map(fn {_id, result} -> result end)
    filtered_results = filter_results(results, socket.assigns)
    sorted_results = sort_results(filtered_results, socket.assigns.sort_by)

    socket
    |> assign(:results_empty?, sorted_results == [])
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp apply_sort(socket) do
    # Re-sort the current results
    results = socket.assigns.search_results |> Enum.map(fn {_id, result} -> result end)
    sorted_results = sort_results(results, socket.assigns.sort_by)

    socket
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp filter_results(results, assigns) do
    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
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

  defp get_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  defp format_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  defp health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end

  defp format_date(nil), do: "Unknown"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

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
    # Check if media already exists by TMDB ID
    tmdb_id = metadata.provider_id

    case Media.get_media_item_by_tmdb(tmdb_id) do
      nil ->
        # Create new media item
        attrs = build_media_item_attrs(parsed, metadata)

        case Media.create_media_item(attrs) do
          {:ok, media_item} ->
            # For TV shows, create episode records
            media_item =
              if parsed.type == :tv_show do
                # If parsed from release with specific season/episodes, create those
                if parsed.season && parsed.episodes do
                  create_episodes_for_release(media_item, parsed)
                end

                # Always fetch all episodes from metadata
                Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all")

                Media.get_media_item!(media_item.id)
              else
                media_item
              end

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

    %{
      type: type,
      title: metadata.title || parsed.title,
      original_title: metadata.original_title,
      year:
        metadata.year ||
          (metadata.release_date && extract_year_from_date(metadata.release_date)) ||
          (metadata.first_air_date && extract_year_from_date(metadata.first_air_date)) ||
          parsed.year,
      tmdb_id: metadata.provider_id,
      metadata: metadata,
      monitored: monitor_by_default
    }
  end

  defp create_episodes_for_release(media_item, parsed) do
    # For each episode in the parsed release, create an episode record
    Enum.each(parsed.episodes || [], fn episode_number ->
      episode_attrs = %{
        media_item_id: media_item.id,
        season_number: parsed.season,
        episode_number: episode_number,
        title: "Episode #{episode_number}",
        monitored: true
      }

      case Media.create_episode(episode_attrs) do
        {:ok, episode} ->
          Logger.debug("Created episode S#{parsed.season}E#{episode_number}")
          episode

        {:error, changeset} ->
          # Episode might already exist, log and continue
          Logger.debug("Episode already exists or error: #{inspect(changeset.errors)}")
          nil
      end
    end)
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

    %{
      type: type,
      title: metadata.title,
      original_title: metadata.original_title,
      year:
        metadata.year ||
          (metadata.release_date && extract_year_from_date(metadata.release_date)) ||
          (metadata.first_air_date && extract_year_from_date(metadata.first_air_date)),
      tmdb_id: metadata.provider_id,
      metadata: metadata,
      monitored: monitor_by_default
    }
  end

  defp format_client_error(error) when is_binary(error), do: error
  defp format_client_error(error), do: inspect(error)

  defp maybe_queue_auto_search(media_item) do
    # Get auto_search_on_add setting from config
    config = Mydia.Config.get()
    auto_search_on_add = config.media.auto_search_on_add

    if auto_search_on_add do
      Logger.info("Auto-search enabled, queueing search job",
        media_item_id: media_item.id,
        title: media_item.title,
        type: media_item.type
      )

      # Queue the appropriate search job based on media type
      job =
        case media_item.type do
          "movie" ->
            %{mode: "specific", media_item_id: media_item.id}
            |> MovieSearch.new()

          "tv_show" ->
            %{mode: "show", media_item_id: media_item.id}
            |> TVShowSearch.new()

          _ ->
            Logger.warning("Unknown media type for auto-search", type: media_item.type)
            nil
        end

      if job do
        case Oban.insert(job) do
          {:ok, _oban_job} ->
            Logger.info("Auto-search job queued successfully",
              media_item_id: media_item.id,
              title: media_item.title
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to queue auto-search job",
              media_item_id: media_item.id,
              title: media_item.title,
              reason: inspect(reason)
            )

            :error
        end
      else
        :ok
      end
    else
      Logger.debug("Auto-search disabled, skipping auto-queue",
        media_item_id: media_item.id,
        title: media_item.title
      )

      :ok
    end
  end
end
