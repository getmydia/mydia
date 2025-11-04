defmodule MydiaWeb.SearchLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.FileParser
  alias Mydia.Metadata
  alias Mydia.Media

  require Logger

  @impl true
  def mount(_params, _session, socket) do
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

  def handle_event("download", %{"url" => _download_url, "title" => title}, socket) do
    # TODO: Implement download functionality
    # For now, just show a flash message
    {:noreply,
     socket
     |> put_flash(:info, "Download functionality coming soon: #{title}")}
  end

  def handle_event("add_to_library", %{"title" => title}, socket) do
    # Start async task to add media to library
    {:noreply,
     socket
     |> start_async(:add_to_library, fn -> add_release_to_library(title) end)}
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

    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:results_empty?, sorted_results == [])
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

  def handle_async(:add_to_library, {:ok, {:ok, media_item}}, socket) do
    Logger.info("Successfully added #{media_item.title} to library")

    {:noreply,
     socket
     |> put_flash(:info, "#{media_item.title} added to library")
     |> push_navigate(to: ~p"/media/#{media_item.id}")}
  end

  def handle_async(:add_to_library, {:ok, {:error, reason}}, socket) do
    Logger.error("Failed to add to library: #{inspect(reason)}")

    error_message =
      case reason do
        :no_metadata_match ->
          "Could not find matching media. Try searching manually."

        :parse_failed ->
          "Could not parse release title. Try adding media manually."

        {:metadata_error, msg} ->
          "Metadata provider error: #{msg}"

        _ ->
          "Failed to add to library: #{inspect(reason)}"
      end

    {:noreply, put_flash(socket, :error, error_message)}
  end

  def handle_async(:add_to_library, {:exit, reason}, socket) do
    Logger.error("Add to library task crashed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Failed to add to library unexpectedly")}
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
         {:ok, metadata} <- search_and_fetch_metadata(parsed),
         {:ok, media_item} <- create_media_item_from_metadata(parsed, metadata) do
      {:ok, media_item}
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

      {:ok, [first_match | _rest]} ->
        Logger.info("Found metadata match: #{first_match["title"] || first_match["name"]}")
        # Fetch full metadata for the first match
        fetch_full_metadata(config, first_match, media_type)

      {:error, reason} ->
        Logger.error("Metadata search failed: #{inspect(reason)}")
        {:error, {:metadata_error, "Search failed"}}
    end
  end

  defp fetch_full_metadata(config, match, media_type) do
    provider_id = match["id"] || match["provider_id"]

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
    tmdb_id = metadata["id"]

    case Media.get_media_item_by_tmdb(tmdb_id) do
      nil ->
        # Create new media item
        attrs = build_media_item_attrs(parsed, metadata)

        case Media.create_media_item(attrs) do
          {:ok, media_item} ->
            # For TV shows, create episode records if parsed from release
            media_item =
              if parsed.type == :tv_show and parsed.season and parsed.episodes do
                create_episodes_for_release(media_item, parsed)
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

    %{
      type: type,
      title: metadata["title"] || metadata["name"] || parsed.title,
      original_title: metadata["original_title"] || metadata["original_name"],
      year:
        (metadata["release_date"] && extract_year_from_date(metadata["release_date"])) ||
          (metadata["first_air_date"] && extract_year_from_date(metadata["first_air_date"])) ||
          parsed.year,
      tmdb_id: metadata["id"],
      metadata: metadata,
      monitored: true
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
end
