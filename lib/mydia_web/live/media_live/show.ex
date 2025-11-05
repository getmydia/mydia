defmodule MydiaWeb.MediaLive.Show do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Settings
  alias Mydia.Library
  alias Mydia.Downloads
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    media_item = load_media_item(id)
    quality_profiles = Settings.list_quality_profiles()

    # Load downloads with real-time status
    downloads_with_status = load_downloads_with_status(media_item)

    # Build timeline events
    timeline_events = build_timeline_events(media_item, downloads_with_status)

    {:ok,
     socket
     |> assign(:media_item, media_item)
     |> assign(:downloads_with_status, downloads_with_status)
     |> assign(:timeline_events, timeline_events)
     |> assign(:page_title, media_item.title)
     |> assign(:show_edit_modal, false)
     |> assign(:show_delete_confirm, false)
     |> assign(:quality_profiles, quality_profiles)
     |> assign(:edit_form, nil)
     |> assign(:show_file_delete_confirm, false)
     |> assign(:file_to_delete, nil)
     |> assign(:show_file_details_modal, false)
     |> assign(:file_details, nil)
     |> assign(:show_download_cancel_confirm, false)
     |> assign(:download_to_cancel, nil)
     |> assign(:show_download_delete_confirm, false)
     |> assign(:download_to_delete, nil)
     |> assign(:show_download_details_modal, false)
     |> assign(:download_details, nil)
     # Manual search modal state
     |> assign(:show_manual_search_modal, false)
     |> assign(:manual_search_query, "")
     |> assign(:manual_search_context, nil)
     |> assign(:searching, false)
     |> assign(:min_seeders, 0)
     |> assign(:quality_filter, nil)
     |> assign(:sort_by, :quality)
     |> assign(:results_empty?, false)
     # Auto search state
     |> assign(:auto_searching, false)
     |> assign(:auto_searching_season, nil)
     |> assign(:auto_searching_episode, nil)
     # File metadata refresh state
     |> assign(:refreshing_file_metadata, false)
     |> assign(:rescanning_season, nil)
     |> stream_configure(:search_results, dom_id: &generate_result_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_monitored", _params, socket) do
    media_item = socket.assigns.media_item
    {:ok, updated_item} = Media.update_media_item(media_item, %{monitored: !media_item.monitored})

    {:noreply,
     socket
     |> assign(:media_item, updated_item)
     |> put_flash(
       :info,
       "Monitoring #{if updated_item.monitored, do: "enabled", else: "disabled"}"
     )}
  end

  def handle_event("manual_search", _params, socket) do
    media_item = socket.assigns.media_item

    # Build search query from media item
    search_query =
      case media_item.type do
        "movie" ->
          # For movies, search with title and year
          if media_item.year do
            "#{media_item.title} #{media_item.year}"
          else
            media_item.title
          end

        "tv_show" ->
          # For TV shows, just use the title
          media_item.title
      end

    # Open modal and start search
    min_seeders = socket.assigns.min_seeders

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(:manual_search_context, %{type: :media_item})
     |> assign(:searching, true)
     |> assign(:results_empty?, false)
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
  end

  def handle_event("auto_search_download", _params, socket) do
    media_item = socket.assigns.media_item
    downloads_with_status = socket.assigns.downloads_with_status

    # Check if auto search is possible
    unless can_auto_search?(media_item, downloads_with_status) do
      message =
        cond do
          is_nil(media_item.quality_profile_id) ->
            "Cannot auto search: No quality profile assigned"

          has_active_download?(downloads_with_status) ->
            "Cannot auto search: Download already in progress"

          true ->
            "Cannot auto search: Prerequisites not met"
        end

      {:noreply, put_flash(socket, :error, message)}
    else
      # Queue the background job based on media type
      case media_item.type do
        "movie" ->
          # Queue MovieSearchJob for this specific movie
          %{mode: "specific", media_item_id: media_item.id}
          |> Mydia.Jobs.MovieSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for movie",
            media_item_id: media_item.id,
            title: media_item.title
          )

          # Set a timeout to reset auto_searching state if no download is created
          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(:info, "Searching indexers for #{media_item.title}...")}

        "tv_show" ->
          # Queue TVShowSearchJob for all missing episodes
          %{mode: "show", media_item_id: media_item.id}
          |> Mydia.Jobs.TVShowSearch.new()
          |> Oban.insert()

          Logger.info("Queued auto search for TV show",
            media_item_id: media_item.id,
            title: media_item.title
          )

          # Set a timeout to reset auto_searching state if no download is created
          Process.send_after(self(), :auto_search_timeout, 30_000)

          {:noreply,
           socket
           |> assign(:auto_searching, true)
           |> put_flash(:info, "Searching for all missing episodes of #{media_item.title}...")}
      end
    end
  end

  def handle_event("refresh_metadata", _params, socket) do
    media_item = socket.assigns.media_item

    case media_item.type do
      "tv_show" ->
        # Refresh episodes for TV shows
        case Media.refresh_episodes_for_tv_show(media_item) do
          {:ok, count} ->
            {:noreply,
             socket
             |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
             |> put_flash(:info, "Refreshed metadata: #{count} episodes added")}

          {:error, :missing_tmdb_id} ->
            {:noreply, put_flash(socket, :error, "Cannot refresh: Missing TMDB ID")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to refresh metadata: #{inspect(reason)}")}
        end

      "movie" ->
        # For movies, just reload metadata (future enhancement could update movie details)
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> put_flash(:info, "Metadata refreshed")}
    end
  end

  def handle_event("refresh_all_file_metadata", _params, socket) do
    media_item = socket.assigns.media_item
    media_files = media_item.media_files

    if Enum.empty?(media_files) do
      {:noreply, put_flash(socket, :info, "No media files to refresh")}
    else
      # Start async task to refresh all file metadata
      {:noreply,
       socket
       |> assign(:refreshing_file_metadata, true)
       |> start_async(:refresh_files, fn -> refresh_files(media_files) end)}
    end
  end

  def handle_event("rescan_season_files", %{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    # Get all media files for episodes in this season
    season_media_files = get_season_media_files(media_item, season_num)

    if Enum.empty?(season_media_files) do
      {:noreply, put_flash(socket, :info, "No media files to refresh for season #{season_num}")}
    else
      # Start async task to refresh season file metadata
      {:noreply,
       socket
       |> assign(:rescanning_season, season_num)
       |> start_async(:rescan_season_files, fn ->
         {season_num, refresh_files(season_media_files)}
       end)}
    end
  end

  def handle_event("show_edit_modal", _params, socket) do
    media_item = socket.assigns.media_item
    changeset = Media.change_media_item(media_item)

    {:noreply,
     socket
     |> assign(:show_edit_modal, true)
     |> assign(:edit_form, to_form(changeset))}
  end

  def handle_event("hide_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_modal, false)
     |> assign(:edit_form, nil)}
  end

  def handle_event("validate_edit", %{"media_item" => media_params}, socket) do
    changeset =
      socket.assigns.media_item
      |> Media.change_media_item(media_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset))}
  end

  def handle_event("save_edit", %{"media_item" => media_params}, socket) do
    media_item = socket.assigns.media_item

    case Media.update_media_item(media_item, media_params) do
      {:ok, updated_item} ->
        {:noreply,
         socket
         |> assign(:media_item, updated_item)
         |> assign(:show_edit_modal, false)
         |> assign(:edit_form, nil)
         |> put_flash(:info, "Settings updated successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, true)}
  end

  def handle_event("hide_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, false)}
  end

  def handle_event("delete_media", _params, socket) do
    media_item = socket.assigns.media_item

    case Media.delete_media_item(media_item) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{media_item.title} deleted successfully")
         |> push_navigate(to: ~p"/media")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete #{media_item.title}")
         |> assign(:show_delete_confirm, false)}
    end
  end

  def handle_event("toggle_episode_monitored", %{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id)
    {:ok, _updated_episode} = Media.update_episode(episode, %{monitored: !episode.monitored})

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(
       :info,
       "Episode monitoring #{if episode.monitored, do: "disabled", else: "enabled"}"
     )}
  end

  def handle_event("monitor_season", %{"season-number" => season_number_str}, socket) do
    season_number = String.to_integer(season_number_str)
    media_item = socket.assigns.media_item

    case Media.update_season_monitoring(media_item.id, season_number, true) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(media_item.id))
         |> put_flash(
           :info,
           "Monitoring enabled for #{count} episodes in Season #{season_number}"
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update season monitoring")}
    end
  end

  def handle_event("unmonitor_season", %{"season-number" => season_number_str}, socket) do
    season_number = String.to_integer(season_number_str)
    media_item = socket.assigns.media_item

    case Media.update_season_monitoring(media_item.id, season_number, false) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(media_item.id))
         |> put_flash(
           :info,
           "Monitoring disabled for #{count} episodes in Season #{season_number}"
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update season monitoring")}
    end
  end

  def handle_event("search_episode", %{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id, preload: [:media_item])
    media_item = episode.media_item

    # Build search query for the episode
    # Format: "Show Title S01E02" or "Show Title 1x02"
    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"

    # Open modal and start search
    min_seeders = socket.assigns.min_seeders

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(:manual_search_context, %{type: :episode, episode_id: episode_id})
     |> assign(:searching, true)
     |> assign(:results_empty?, false)
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
  end

  def handle_event("manual_search_season", %{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    # Build search query for the season
    # Format: "Show Title S01"
    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(season_num), 2, "0")}"

    # Open modal and start search
    min_seeders = socket.assigns.min_seeders

    {:noreply,
     socket
     |> assign(:show_manual_search_modal, true)
     |> assign(:manual_search_query, search_query)
     |> assign(:manual_search_context, %{type: :season, season_number: season_num})
     |> assign(:searching, true)
     |> assign(:results_empty?, false)
     |> stream(:search_results, [], reset: true)
     |> start_async(:search, fn -> perform_search(search_query, min_seeders) end)}
  end

  def handle_event("auto_search_season", %{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    # Queue TVShowSearchJob with season mode
    %{mode: "season", media_item_id: media_item.id, season_number: season_num}
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for season",
      media_item_id: media_item.id,
      season_number: season_num,
      title: media_item.title
    )

    # Set a timeout to reset auto_searching_season state if no download is created
    Process.send_after(self(), {:auto_search_season_timeout, season_num}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_season, season_num)
     |> put_flash(:info, "Searching for season #{season_num} (preferring season pack)...")}
  end

  def handle_event("auto_search_episode", %{"episode-id" => episode_id}, socket) do
    # Load episode to get details for flash message
    episode = Media.get_episode!(episode_id)

    # Queue TVShowSearchJob with specific episode mode
    %{mode: "specific", episode_id: episode_id}
    |> Mydia.Jobs.TVShowSearch.new()
    |> Oban.insert()

    Logger.info("Queued auto search for episode",
      episode_id: episode_id,
      season_number: episode.season_number,
      episode_number: episode.episode_number
    )

    # Set a timeout to reset auto_searching_episode state if no download is created
    Process.send_after(self(), {:auto_search_episode_timeout, episode_id}, 30_000)

    {:noreply,
     socket
     |> assign(:auto_searching_episode, episode_id)
     |> put_flash(
       :info,
       "Searching for S#{episode.season_number}E#{episode.episode_number}..."
     )}
  end

  def handle_event("show_file_delete_confirm", %{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id)

    {:noreply,
     socket
     |> assign(:show_file_delete_confirm, true)
     |> assign(:file_to_delete, file)}
  end

  def handle_event("hide_file_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_file_delete_confirm, false)
     |> assign(:file_to_delete, nil)}
  end

  def handle_event("delete_media_file", _params, socket) do
    file = socket.assigns.file_to_delete

    case Library.delete_media_file(file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> assign(:show_file_delete_confirm, false)
         |> assign(:file_to_delete, nil)
         |> put_flash(:info, "Media file deleted successfully")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete media file")
         |> assign(:show_file_delete_confirm, false)
         |> assign(:file_to_delete, nil)}
    end
  end

  def handle_event("show_file_details", %{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id)

    {:noreply,
     socket
     |> assign(:show_file_details_modal, true)
     |> assign(:file_details, file)}
  end

  def handle_event("hide_file_details", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_file_details_modal, false)
     |> assign(:file_details, nil)}
  end

  def handle_event("mark_file_preferred", %{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id)
    media_item = socket.assigns.media_item

    # Mark this file with the media item's quality profile
    case Library.update_media_file(file, %{quality_profile_id: media_item.quality_profile_id}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> put_flash(:info, "Marked as preferred version")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to mark file as preferred")}
    end
  end

  def handle_event("retry_download", %{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id, preload: [:media_item, :episode])

    # Clear error message if any
    case Downloads.update_download(download, %{error_message: nil}) do
      {:ok, updated} ->
        # Re-add to client using the original download URL
        search_result = %Mydia.Indexers.SearchResult{
          download_url: updated.download_url,
          title: updated.title,
          indexer: updated.indexer,
          size: updated.metadata["size"],
          seeders: updated.metadata["seeders"],
          leechers: updated.metadata["leechers"],
          quality: updated.metadata["quality"]
        }

        opts =
          []
          |> maybe_add_opt(:media_item_id, updated.media_item_id)
          |> maybe_add_opt(:episode_id, updated.episode_id)
          |> maybe_add_opt(:client_name, updated.download_client)

        # Delete old download record and create new one
        Downloads.delete_download(updated)

        case Downloads.initiate_download(search_result, opts) do
          {:ok, _new_download} ->
            {:noreply, put_flash(socket, :info, "Download re-initiated")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to retry download: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update download")}
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def handle_event("show_download_cancel_confirm", %{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_cancel_confirm, true)
     |> assign(:download_to_cancel, download)}
  end

  def handle_event("hide_download_cancel_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_cancel_confirm, false)
     |> assign(:download_to_cancel, nil)}
  end

  def handle_event("cancel_download", _params, socket) do
    download = socket.assigns.download_to_cancel

    case Downloads.cancel_download(download) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_download_cancel_confirm, false)
         |> assign(:download_to_cancel, nil)
         |> put_flash(:info, "Download cancelled")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to cancel download")
         |> assign(:show_download_cancel_confirm, false)
         |> assign(:download_to_cancel, nil)}
    end
  end

  def handle_event("show_download_delete_confirm", %{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_delete_confirm, true)
     |> assign(:download_to_delete, download)}
  end

  def handle_event("hide_download_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_delete_confirm, false)
     |> assign(:download_to_delete, nil)}
  end

  def handle_event("delete_download_record", _params, socket) do
    download = socket.assigns.download_to_delete

    case Downloads.delete_download(download) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> assign(:show_download_delete_confirm, false)
         |> assign(:download_to_delete, nil)
         |> put_flash(:info, "Download removed from history")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete download")
         |> assign(:show_download_delete_confirm, false)
         |> assign(:download_to_delete, nil)}
    end
  end

  def handle_event("show_download_details", %{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_details_modal, true)
     |> assign(:download_details, download)}
  end

  def handle_event("hide_download_details", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_details_modal, false)
     |> assign(:download_details, nil)}
  end

  def handle_event("close_manual_search_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_manual_search_modal, false)
     |> assign(:manual_search_query, "")
     |> assign(:manual_search_context, nil)
     |> assign(:searching, false)
     |> assign(:results_empty?, false)
     |> stream(:search_results, [], reset: true)}
  end

  def handle_event("filter_search", params, socket) do
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

    {:noreply,
     socket
     |> assign(:min_seeders, min_seeders)
     |> assign(:quality_filter, quality_filter)
     |> apply_search_filters()}
  end

  def handle_event("sort_search", %{"sort_by" => sort_by}, socket) do
    sort_by = String.to_existing_atom(sort_by)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> apply_search_sort()}
  end

  def handle_event(
        "download_from_search",
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
    media_item = socket.assigns.media_item
    context = socket.assigns.manual_search_context

    # Determine if this is for a specific episode or the media item
    {media_item_id, episode_id} =
      case context do
        %{type: :episode, episode_id: ep_id} ->
          {media_item.id, ep_id}

        %{type: :season, season_number: _season_num} ->
          # Season pack - associate with media item, not specific episode
          {media_item.id, nil}

        _ ->
          {media_item.id, nil}
      end

    # Create SearchResult struct to pass to initiate_download
    search_result = %SearchResult{
      download_url: download_url,
      title: title,
      indexer: indexer,
      size: parse_int(size),
      seeders: parse_int(seeders),
      leechers: parse_int(leechers),
      quality: quality
    }

    # Build options for initiate_download
    opts =
      []
      |> maybe_add_opt(:media_item_id, media_item_id)
      |> maybe_add_opt(:episode_id, episode_id)

    case Downloads.initiate_download(search_result, opts) do
      {:ok, _download} ->
        Logger.info("Download initiated: #{title}")

        {:noreply,
         socket
         |> put_flash(:info, "Download started: #{title}")
         |> assign(:media_item, load_media_item(media_item.id))
         |> assign(
           :downloads_with_status,
           load_downloads_with_status(load_media_item(media_item.id))
         )
         |> assign(:show_manual_search_modal, false)
         |> assign(:manual_search_query, "")
         |> assign(:manual_search_context, nil)
         |> assign(:searching, false)
         |> assign(:results_empty?, false)
         |> stream(:search_results, [], reset: true)}

      {:error, reason} ->
        Logger.error("Failed to initiate download: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to start download: #{inspect(reason)}")}
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  @impl true
  def handle_info({:download_created, download}, socket) do
    if download_for_media?(download, socket.assigns.media_item) do
      media_item = load_media_item(socket.assigns.media_item.id)
      downloads_with_status = load_downloads_with_status(media_item)
      timeline_events = build_timeline_events(media_item, downloads_with_status)

      # If auto searching was in progress, show success message
      socket =
        cond do
          socket.assigns.auto_searching ->
            put_flash(socket, :info, "Download started: #{download.title}")

          socket.assigns.auto_searching_season &&
            download.episode_id &&
              episode_in_season?(download.episode_id, socket.assigns.auto_searching_season) ->
            put_flash(socket, :info, "Download started: #{download.title}")

          socket.assigns.auto_searching_episode &&
              download.episode_id == socket.assigns.auto_searching_episode ->
            put_flash(socket, :info, "Download started: #{download.title}")

          true ->
            socket
        end

      {:noreply,
       socket
       |> assign(:media_item, media_item)
       |> assign(:downloads_with_status, downloads_with_status)
       |> assign(:timeline_events, timeline_events)
       |> assign(:auto_searching, false)
       |> assign(:auto_searching_season, nil)
       |> assign(:auto_searching_episode, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:download_updated, _download_id}, socket) do
    # Reload media item and downloads with status
    media_item = load_media_item(socket.assigns.media_item.id)
    downloads_with_status = load_downloads_with_status(media_item)
    timeline_events = build_timeline_events(media_item, downloads_with_status)

    {:noreply,
     socket
     |> assign(:media_item, media_item)
     |> assign(:downloads_with_status, downloads_with_status)
     |> assign(:timeline_events, timeline_events)}
  end

  def handle_info(:auto_search_timeout, socket) do
    # If auto_searching is still true after timeout, reset it and show message
    socket =
      if socket.assigns.auto_searching do
        socket
        |> assign(:auto_searching, false)
        |> put_flash(:warning, "Search completed but no suitable releases found")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:auto_search_season_timeout, season_num}, socket) do
    # If auto_searching_season is still set after timeout, reset it and show message
    socket =
      if socket.assigns.auto_searching_season == season_num do
        socket
        |> assign(:auto_searching_season, nil)
        |> put_flash(
          :warning,
          "Search completed but no suitable releases found for season #{season_num}"
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:auto_search_episode_timeout, episode_id}, socket) do
    # If auto_searching_episode is still set after timeout, reset it and show message
    socket =
      if socket.assigns.auto_searching_episode == episode_id do
        episode = Media.get_episode!(episode_id)

        socket
        |> assign(:auto_searching_episode, nil)
        |> put_flash(
          :warning,
          "Search completed but no suitable releases found for S#{episode.season_number}E#{episode.episode_number}"
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:search, {:ok, {:ok, results}}, socket) do
    start_time = System.monotonic_time(:millisecond)

    filtered_results = filter_search_results(results, socket.assigns)
    sorted_results = sort_search_results(filtered_results, socket.assigns.sort_by)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Search completed: query=\"#{socket.assigns.manual_search_query}\", " <>
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

  def handle_async(:refresh_files, {:ok, {:ok, success_count, error_count}}, socket) do
    message =
      if error_count > 0 do
        "Refreshed #{success_count} file(s), #{error_count} failed"
      else
        "Successfully refreshed #{success_count} file(s)"
      end

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_async(:refresh_files, {:ok, {:error, reason}}, socket) do
    Logger.error("File metadata refresh failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> put_flash(:error, "Failed to refresh file metadata: #{inspect(reason)}")}
  end

  def handle_async(:refresh_files, {:exit, reason}, socket) do
    Logger.error("File metadata refresh task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> put_flash(:error, "Metadata refresh failed unexpectedly")}
  end

  def handle_async(
        :rescan_season_files,
        {:ok, {season_num, {:ok, success_count, error_count}}},
        socket
      ) do
    message =
      if error_count > 0 do
        "Re-scanned #{success_count} file(s) in Season #{season_num}, #{error_count} failed"
      else
        "Successfully re-scanned #{success_count} file(s) in Season #{season_num}"
      end

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_async(:rescan_season_files, {:ok, {season_num, {:error, reason}}}, socket) do
    Logger.error("Season file metadata refresh failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Failed to refresh Season #{season_num} files: #{inspect(reason)}")}
  end

  def handle_async(:rescan_season_files, {:exit, reason}, socket) do
    Logger.error("Season file metadata refresh task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Season metadata refresh failed unexpectedly")}
  end

  defp load_media_item(id) do
    preload_list = build_preload_list()

    Media.get_media_item!(id, preload: preload_list)
  end

  defp build_preload_list do
    [
      quality_profile: [],
      episodes: [:media_files, downloads: :media_item],
      media_files: [],
      downloads: []
    ]
  end

  defp download_for_media?(download, media_item) do
    download.media_item_id == media_item.id or
      (download.episode_id &&
         Enum.any?(media_item.episodes, fn ep -> ep.id == download.episode_id end))
  end

  defp load_downloads_with_status(media_item) do
    # Get all downloads with real-time status from clients
    all_downloads = Downloads.list_downloads_with_status(filter: :all)

    # Filter to only downloads for this media item
    all_downloads
    |> Enum.filter(fn download_map ->
      download_map.media_item_id == media_item.id or
        (download_map.episode_id &&
           Enum.any?(media_item.episodes || [], fn ep -> ep.id == download_map.episode_id end))
    end)
  end

  defp get_poster_url(media_item) do
    case media_item.metadata do
      %{"poster_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/w500#{path}"

      _ ->
        "/images/no-poster.jpg"
    end
  end

  defp get_backdrop_url(media_item) do
    case media_item.metadata do
      %{"backdrop_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/original#{path}"

      _ ->
        nil
    end
  end

  defp get_overview(media_item) do
    case media_item.metadata do
      %{"overview" => overview} when is_binary(overview) and overview != "" ->
        overview

      _ ->
        "No overview available."
    end
  end

  defp get_rating(media_item) do
    case media_item.metadata do
      %{"vote_average" => rating} when is_number(rating) ->
        Float.round(rating, 1)

      _ ->
        nil
    end
  end

  defp get_runtime(media_item) do
    case media_item.metadata do
      %{"runtime" => runtime} when is_integer(runtime) and runtime > 0 ->
        hours = div(runtime, 60)
        minutes = rem(runtime, 60)

        cond do
          hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
          hours > 0 -> "#{hours}h"
          true -> "#{minutes}m"
        end

      _ ->
        nil
    end
  end

  defp get_genres(media_item) do
    case media_item.metadata do
      %{"genres" => genres} when is_list(genres) ->
        Enum.map(genres, fn
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp get_cast(media_item, limit \\ 6) do
    case media_item.metadata do
      %{"credits" => %{"cast" => cast}} when is_list(cast) ->
        cast
        |> Enum.take(limit)
        |> Enum.map(fn actor ->
          %{
            name: actor["name"],
            character: actor["character"],
            profile_path: actor["profile_path"]
          }
        end)

      _ ->
        []
    end
  end

  defp get_crew(media_item) do
    case media_item.metadata do
      %{"credits" => %{"crew" => crew}} when is_list(crew) ->
        # Get key crew members (directors, writers, producers)
        crew
        |> Enum.filter(fn member ->
          member["job"] in ["Director", "Writer", "Screenplay", "Executive Producer", "Producer"]
        end)
        |> Enum.uniq_by(fn member -> {member["name"], member["job"]} end)
        |> Enum.take(6)
        |> Enum.map(fn member ->
          %{name: member["name"], job: member["job"]}
        end)

      _ ->
        []
    end
  end

  defp get_profile_image_url(nil), do: nil

  defp get_profile_image_url(path) when is_binary(path) do
    "https://image.tmdb.org/t/p/w185#{path}"
  end

  defp format_file_size(nil), do: "N/A"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_date(nil), do: "N/A"

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp group_episodes_by_season(episodes) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.sort_by(fn {season, _} -> season end, :desc)
  end

  defp get_episode_quality_badge(episode) do
    case episode.media_files do
      [] ->
        nil

      files ->
        files
        |> Enum.map(& &1.resolution)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(:desc)
        |> List.first()
    end
  end

  # Episode status helpers - delegates to EpisodeStatus module
  defp get_episode_status(episode) do
    EpisodeStatus.get_episode_status_with_downloads(episode)
  end

  defp episode_status_color(status) do
    EpisodeStatus.status_color(status)
  end

  defp episode_status_icon(status) do
    EpisodeStatus.status_icon(status)
  end

  defp episode_status_label(status) do
    EpisodeStatus.status_label(status)
  end

  defp episode_status_details(episode) do
    EpisodeStatus.status_details(episode)
  end

  defp get_download_status(downloads_with_status) do
    active_downloads =
      downloads_with_status
      |> Enum.filter(fn d -> d.status in ["downloading", "seeding", "checking", "paused"] end)

    case active_downloads do
      [] -> nil
      [download | _] -> download
    end
  end

  defp format_download_status("pending"), do: "Queued"
  defp format_download_status("downloading"), do: "Downloading"
  defp format_download_status("seeding"), do: "Seeding"
  defp format_download_status("checking"), do: "Checking"
  defp format_download_status("paused"), do: "Paused"
  defp format_download_status("completed"), do: "Completed"
  defp format_download_status("failed"), do: "Failed"
  defp format_download_status("cancelled"), do: "Cancelled"
  defp format_download_status("missing"), do: "Missing"
  defp format_download_status(_), do: "Unknown"

  ## Timeline Functions

  defp build_timeline_events(media_item, downloads_with_status) do
    events = []

    # Add media item added event
    events = [
      %{
        type: :media_added,
        timestamp: media_item.inserted_at,
        title: "Added to Library",
        description: "#{media_item.title} was added to your library",
        icon: "hero-plus-circle",
        color: "text-info",
        metadata: nil
      }
      | events
    ]

    # Add download events
    download_events =
      downloads_with_status
      |> Enum.flat_map(fn download ->
        initiated_event = %{
          type: :download_initiated,
          timestamp: download.inserted_at,
          title: "Download Started",
          description: download.title,
          icon: "hero-arrow-down-tray",
          color: "text-primary",
          metadata: %{
            quality: download.metadata["quality"],
            indexer: download.indexer
          }
        }

        completion_events =
          cond do
            download.status == "completed" && download.completed_at ->
              [
                %{
                  type: :download_completed,
                  timestamp: download.completed_at,
                  title: "Download Completed",
                  description: download.title,
                  icon: "hero-check-circle",
                  color: "text-success",
                  metadata: %{quality: download.metadata["quality"]}
                }
              ]

            download.status == "failed" ->
              [
                %{
                  type: :download_failed,
                  timestamp: download.updated_at,
                  title: "Download Failed",
                  description: download.title,
                  icon: "hero-x-circle",
                  color: "text-error",
                  metadata: %{error: download.error_message}
                }
              ]

            download.status == "cancelled" ->
              [
                %{
                  type: :download_cancelled,
                  timestamp: download.updated_at,
                  title: "Download Cancelled",
                  description: download.title,
                  icon: "hero-minus-circle",
                  color: "text-warning",
                  metadata: nil
                }
              ]

            true ->
              []
          end

        [initiated_event | completion_events]
      end)

    events = events ++ download_events

    # Add media file import events
    file_events =
      media_item.media_files
      |> Enum.map(fn file ->
        %{
          type: :file_imported,
          timestamp: file.inserted_at,
          title: "File Imported",
          description: Path.basename(file.path),
          icon: "hero-document-check",
          color: "text-success",
          metadata: %{
            resolution: file.resolution,
            codec: file.codec,
            size: file.size
          }
        }
      end)

    events = events ++ file_events

    # Add episode refresh events for TV shows
    episode_events =
      if media_item.type == "tv_show" && media_item.episodes do
        # Group episodes by inserted_at date to detect batch imports
        media_item.episodes
        |> Enum.group_by(fn ep ->
          ep.inserted_at
          |> DateTime.truncate(:second)
        end)
        |> Enum.map(fn {timestamp, episodes} ->
          count = length(episodes)

          %{
            type: :episodes_refreshed,
            timestamp: timestamp,
            title: "Episodes Updated",
            description: "#{count} episode#{if count > 1, do: "s", else: ""} added/updated",
            icon: "hero-arrow-path",
            color: "text-info",
            metadata: %{count: count}
          }
        end)
      else
        []
      end

    events = events ++ episode_events

    # Sort all events by timestamp (newest first)
    events
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
  end

  defp format_relative_time(timestamp) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, timestamp, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} minutes ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      diff < 2_592_000 -> "#{div(diff, 86400)} days ago"
      diff < 31_536_000 -> "#{div(diff, 2_592_000)} months ago"
      true -> "#{div(diff, 31_536_000)} years ago"
    end
  end

  defp format_absolute_time(timestamp) do
    Calendar.strftime(timestamp, "%b %d, %Y at %I:%M %p")
  end

  ## Manual Search Functions

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

  defp apply_search_filters(socket) do
    # Re-filter the current results without re-searching
    results = socket.assigns.search_results |> Enum.map(fn {_id, result} -> result end)
    filtered_results = filter_search_results(results, socket.assigns)
    sorted_results = sort_search_results(filtered_results, socket.assigns.sort_by)

    socket
    |> assign(:results_empty?, sorted_results == [])
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp apply_search_sort(socket) do
    # Re-sort the current results
    results = socket.assigns.search_results |> Enum.map(fn {_id, result} -> result end)
    sorted_results = sort_search_results(results, socket.assigns.sort_by)

    socket
    |> stream(:search_results, sorted_results, reset: true)
  end

  defp filter_search_results(results, assigns) do
    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
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

  defp normalize_resolution("2160p"), do: "4k"
  defp normalize_resolution("4k"), do: "4k"
  defp normalize_resolution(res), do: String.downcase(res)

  defp sort_search_results(results, :quality) do
    # Sort by quality score (already done by search_all), then by seeders
    results
    |> Enum.sort_by(fn result -> {quality_score(result), result.seeders} end, :desc)
  end

  defp sort_search_results(results, :seeders) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  defp sort_search_results(results, :size) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  defp sort_search_results(results, :date) do
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

  # Helper functions for the search results template

  defp get_search_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  defp format_search_size(%SearchResult{} = result) do
    SearchResult.format_size(result)
  end

  defp search_health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end

  defp format_search_date(nil), do: "Unknown"

  defp format_search_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  # Auto search helper functions

  defp can_auto_search?(%Media.MediaItem{} = media_item, downloads_with_status) do
    # Can auto search if:
    # 1. Has a quality profile assigned
    # 2. Is a supported media type (movie or tv_show)
    # 3. No active downloads currently in progress
    has_quality_profile = not is_nil(media_item.quality_profile_id)
    is_supported_type = media_item.type in ["movie", "tv_show"]

    has_quality_profile and is_supported_type and not has_active_download?(downloads_with_status)
  end

  defp has_active_download?(downloads_with_status) do
    Enum.any?(downloads_with_status, fn d ->
      d.status in ["downloading", "seeding", "checking", "paused"]
    end)
  end

  defp episode_in_season?(episode_id, season_num) do
    episode = Media.get_episode!(episode_id)
    episode.season_number == season_num
  end

  # Download quality formatting

  defp format_download_quality(nil), do: "Unknown"

  defp format_download_quality(quality) when is_map(quality) do
    # Build a concise quality description from the quality map
    parts =
      [
        quality["resolution"] || quality[:resolution],
        quality["source"] || quality[:source],
        (quality["hdr"] || quality[:hdr]) && "HDR"
      ]
      |> Enum.filter(& &1)

    case Enum.join(parts, " ") do
      "" -> "Unknown"
      description -> description
    end
  end

  defp format_download_quality(_), do: "Unknown"

  # Helper to get all media files for episodes in a specific season
  defp get_season_media_files(media_item, season_number) do
    media_item.episodes
    |> Enum.filter(&(&1.season_number == season_number))
    |> Enum.flat_map(& &1.media_files)
  end

  # File metadata refresh helper
  defp refresh_files(media_files) do
    Logger.info("Starting file metadata refresh", file_count: length(media_files))

    results =
      Enum.map(media_files, fn file ->
        case Library.refresh_file_metadata(file) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))

    Logger.info("Completed file metadata refresh",
      success: success_count,
      errors: error_count
    )

    {:ok, success_count, error_count}
  end
end
