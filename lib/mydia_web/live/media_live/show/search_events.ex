defmodule MydiaWeb.MediaLive.Show.SearchEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3, stream: 4, stream_insert: 3]

  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.SearchHelpers
  import MydiaWeb.MediaLive.Show.Helpers, only: [parse_int: 1, maybe_add_opt: 3]

  require Logger

  def manual_search(_params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item

      search_query =
        case media_item.type do
          "movie" ->
            if media_item.year do
              "#{media_item.title} #{media_item.year}"
            else
              media_item.title
            end

          "tv_show" ->
            media_item.title
        end

      min_seeders = socket.assigns.min_seeders

      {:noreply,
       socket
       |> assign(:show_manual_search_modal, true)
       |> assign(:manual_search_query, search_query)
       |> assign(:manual_search_context, %{type: :media_item})
       |> assign(:searching, true)
       |> assign(:results_empty?, false)
       |> assign(:download_error, nil)
       |> stream(:search_results, [], reset: true)
       |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def auto_search_download(_params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item

      case media_item.type do
        "movie" ->
          %{mode: "specific", media_item_id: media_item.id}
          |> Mydia.Jobs.MovieSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for movie",
            media_item_id: media_item.id,
            title: media_item.title
          )

          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(:info, "Searching indexers for #{media_item.title}...")}

        "tv_show" ->
          %{mode: "show", media_item_id: media_item.id}
          |> Mydia.Jobs.TVShowSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for TV show",
            media_item_id: media_item.id,
            title: media_item.title
          )

          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(:info, "Searching for all missing episodes of #{media_item.title}...")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def search_episode(%{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id, preload: [:media_item])
    media_item = episode.media_item

    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"

    min_seeders = socket.assigns.min_seeders

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(
       :manual_search_context,
       %{
         type: :episode,
         episode_id: episode_id,
         season_number: episode.season_number,
         episode_number: episode.episode_number
       }
     )
     |> assign(:searching, true)
     |> assign(:results_empty?, false)
     |> assign(:download_error, nil)
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
  end

  def manual_search_season(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(season_num), 2, "0")}"

    min_seeders = socket.assigns.min_seeders

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(:manual_search_context, %{type: :season, season_number: season_num})
     |> assign(:searching, true)
     |> assign(:results_empty?, false)
     |> assign(:download_error, nil)
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
  end

  def auto_search_season(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    %{mode: "season", media_item_id: media_item.id, season_number: season_num}
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for season",
      media_item_id: media_item.id,
      season_number: season_num,
      title: media_item.title
    )

    Process.send_after(self(), {:auto_search_season_timeout, season_num}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_season, season_num)
     |> put_flash(:info, "Searching for season #{season_num} (preferring season pack)...")}
  end

  def auto_search_episode(%{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id)

    %{mode: "specific", episode_id: episode_id}
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for episode",
      episode_id: episode_id,
      season_number: episode.season_number,
      episode_number: episode.episode_number
    )

    Process.send_after(self(), {:auto_search_episode_timeout, episode_id}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_episode, episode_id)
     |> put_flash(
       :info,
       "Searching for S#{episode.season_number}E#{episode.episode_number}..."
     )}
  end

  def close_manual_search_modal(_params, socket) do
    {:noreply, reset_search_modal(socket)}
  end

  defp reset_search_modal(socket) do
    socket
    |> assign(:show_manual_search_modal, false)
    |> assign(:manual_search_query, "")
    |> assign(:manual_search_context, nil)
    |> assign(:searching, false)
    |> assign(:results_empty?, false)
    |> assign(:raw_search_results, [])
    |> assign(:indexer_errors, [])
    |> assign(:download_error, nil)
    |> stream(:search_results, [], reset: true)
  end

  def filter_search(params, socket) do
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

    {:noreply,
     socket
     |> assign(:min_seeders, min_seeders)
     |> assign(:quality_filter, quality_filter)
     |> apply_search_filters()}
  end

  def sort_search(%{"sort_by" => sort_by}, socket) do
    sort_by = String.to_existing_atom(sort_by)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> apply_search_sort()}
  end

  def download_from_search(
        %{
          "download-url" => download_url,
          "title" => title,
          "indexer" => indexer,
          "size" => size,
          "seeders" => seeders,
          "leechers" => leechers,
          "quality" => quality
        },
        socket
      ) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item
      context = socket.assigns.manual_search_context

      {media_item_id, episode_id, metadata} =
        case context do
          %{type: :episode, episode_id: ep_id} ->
            {media_item.id, ep_id, nil}

          %{type: :season, season_number: season_num} ->
            # Tag the request as a season pack so duplicate detection and
            # category routing are scoped to this season rather than the whole
            # show. Without this, an active download for a *different* season
            # falsely reports :duplicate_download.
            {media_item.id, nil,
             %SearchResultMetadata{season_pack: true, season_number: season_num}}

          _ ->
            {media_item.id, nil, nil}
        end

      search_result = %SearchResult{
        download_url: download_url,
        title: title,
        indexer: indexer,
        size: parse_int(size),
        seeders: parse_int(seeders),
        leechers: parse_int(leechers),
        quality: quality,
        metadata: metadata
      }

      opts =
        [manual: true]
        |> maybe_add_opt(:media_item_id, media_item_id)
        |> maybe_add_opt(:episode_id, episode_id)

      case Downloads.grab_async(search_result, opts) do
        {:ok, _download} ->
          socket =
            socket
            |> assign(:download_error, nil)
            |> mark_result(download_url, %{
              downloading: true,
              downloaded: false,
              grab_failed: nil,
              duplicate: false
            })

          socket =
            if socket.assigns.close_after_grab do
              socket
              |> reset_search_modal()
              |> put_flash(:info, "Grabbing \"#{title}\" — progress will appear on this page")
            else
              socket
            end

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, assign(socket, :download_error, "Could not start download for \"#{title}\"")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Re-stream a single result row with extra fields merged in (e.g. `:downloading`,
  # `:downloaded`). Streams don't re-render existing items on parent assign changes,
  # so per-row state must be pushed via stream_insert.
  defp mark_result(socket, download_url, extra) do
    case find_prepared_result(socket, download_url) do
      nil -> socket
      item -> stream_insert(socket, :search_results, Map.merge(item, extra))
    end
  end

  defp find_prepared_result(socket, download_url) do
    raw_results = Map.get(socket.assigns, :raw_search_results, [])
    assigns = socket.assigns
    ranking_opts = build_manual_ranking_opts(assigns)

    raw_results
    |> filter_search_results(assigns)
    |> sort_search_results_with_opts(assigns.sort_by, ranking_opts)
    |> prepare_for_stream()
    |> Enum.find(&(&1.download_url == download_url))
  end

  # handle_async dispatches

  def handle_search_async({:ok, {:ok, results, indexer_errors}}, socket) do
    start_time = System.monotonic_time(:millisecond)

    search_query = socket.assigns.manual_search_query

    filtered_results = filter_search_results(results, socket.assigns)
    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted_results =
      sort_search_results_with_opts(filtered_results, socket.assigns.sort_by, ranking_opts)

    prepared_results = prepare_for_stream(sorted_results)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Search completed: query=\"#{search_query}\", " <>
        "results=#{length(results)}, filtered=#{length(filtered_results)}, " <>
        "indexer_errors=#{length(indexer_errors)}, processing_time=#{duration}ms"
    )

    {:noreply,
     socket
     |> assign(:searching, false)
     |> assign(:results_empty?, sorted_results == [])
     |> assign(:raw_search_results, results)
     |> assign(:indexer_errors, indexer_errors)
     |> stream(:search_results, prepared_results, reset: true)}
  end

  def handle_search_async({:ok, {:error, reason}}, socket) do
    Logger.error("Search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, "Search failed: #{inspect(reason)}")}
  end

  def handle_search_async({:exit, reason}, socket) do
    Logger.error("Search task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching, false)
     |> put_flash(:error, "Search failed unexpectedly")}
  end

  # Grab pipeline PubSub handlers (topic "downloads", broadcast by
  # Mydia.Downloads.Grabber). Row lookup is a no-op when the modal is closed.

  def handle_grab_completed(%{download_url: download_url}, socket) do
    {:noreply, mark_result(socket, download_url, %{downloading: false, downloaded: true})}
  end

  def handle_grab_failed(%{download_url: download_url, reason: reason}, socket) do
    {:noreply, mark_result(socket, download_url, %{downloading: false, grab_failed: reason})}
  end

  def handle_grab_duplicate(%{download_url: download_url}, socket) do
    {:noreply, mark_result(socket, download_url, %{downloading: false, duplicate: true})}
  end
end
