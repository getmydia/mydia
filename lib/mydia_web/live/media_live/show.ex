defmodule MydiaWeb.MediaLive.Show do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Settings
  alias Mydia.Library
  alias Mydia.Downloads
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Events
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.MediaLive.Show.Modals
  alias MydiaWeb.MediaLive.Show.Components

  # Import helper modules
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers
  import MydiaWeb.MediaLive.Show.SearchHelpers
  import MydiaWeb.MediaLive.Show.Loaders

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "events:all")
    end

    media_item = load_media_item(id)
    quality_profiles = Settings.list_quality_profiles()

    # Load downloads with real-time status
    downloads_with_status = load_downloads_with_status(media_item)

    # Load timeline events from Events system
    timeline_events = load_timeline_events(media_item)

    # Initialize expanded seasons - expand the first (most recent) season by default
    expanded_seasons =
      case media_item.type do
        "tv_show" ->
          media_item.episodes
          |> Enum.map(& &1.season_number)
          |> Enum.uniq()
          |> Enum.sort(:desc)
          |> List.first()
          |> case do
            nil -> MapSet.new()
            season_num -> MapSet.new([season_num])
          end

        _ ->
          MapSet.new()
      end

    # Load next episode for TV shows
    {next_episode, next_episode_state} = load_next_episode(media_item, socket)

    {:ok,
     socket
     |> assign(:media_item, media_item)
     |> assign(:downloads_with_status, downloads_with_status)
     |> assign(:timeline_events, timeline_events)
     |> assign(:page_title, media_item.title)
     |> assign(:show_edit_modal, false)
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_files, false)
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
     # File rename modal state
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:renaming_files, false)
     # Season expanded/collapsed state
     |> assign(:expanded_seasons, expanded_seasons)
     # Next episode for TV shows
     |> assign(:next_episode, next_episode)
     |> assign(:next_episode_state, next_episode_state)
     # Feature flags
     |> assign(:playback_enabled, playback_enabled?())
     |> stream_configure(:search_results, dom_id: &generate_result_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_monitored", _params, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item

      {:ok, updated_item} =
        Media.update_media_item(media_item, %{monitored: !media_item.monitored})

      {:noreply,
       socket
       |> assign(:media_item, updated_item)
       |> put_flash(
         :info,
         "Monitoring #{if updated_item.monitored, do: "enabled", else: "disabled"}"
       )}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("manual_search", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("auto_search_download", _params, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      media_item = socket.assigns.media_item

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
    else
      {:unauthorized, socket} -> {:noreply, socket}
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

  def handle_event("rescan_series", _params, socket) do
    media_item = socket.assigns.media_item

    if media_item.type != "tv_show" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
    else
      # Start async task to re-scan the series directory for new files AND refresh metadata
      {:noreply,
       socket
       |> put_flash(:info, "Re-scanning series: discovering new files and refreshing metadata...")
       |> start_async(:rescan_series, fn ->
         # Step 1: Discover new files in the directory
         scan_result = Library.rescan_series(media_item.id)

         # Step 2: Refresh file metadata for all files (existing + new)
         case scan_result do
           {:ok, _result} ->
             # Reload the media item to get the updated file list
             updated_media_item = Media.get_media_item!(media_item.id, preload: [:episodes])
             all_media_files = Enum.flat_map(updated_media_item.episodes, & &1.media_files)
             refresh_result = refresh_files(all_media_files)
             {scan_result, refresh_result}

           error ->
             {error, {:ok, 0, 0}}
         end
       end)}
    end
  end

  def handle_event("rescan_season", %{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    if media_item.type != "tv_show" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
    else
      # Start async task to re-scan the season for new files AND refresh metadata
      {:noreply,
       socket
       |> assign(:rescanning_season, season_num)
       |> put_flash(
         :info,
         "Re-scanning season #{season_num}: discovering new files and refreshing metadata..."
       )
       |> start_async(:rescan_season, fn ->
         # Step 1: Discover new files in the season directory
         scan_result = Library.rescan_season(media_item.id, season_num)

         # Step 2: Refresh file metadata for all season files (existing + new)
         case scan_result do
           {:ok, _result} ->
             # Reload the media item to get the updated file list
             updated_media_item = Media.get_media_item!(media_item.id, preload: [:episodes])
             season_media_files = get_season_media_files(updated_media_item, season_num)
             refresh_result = refresh_files(season_media_files)
             {season_num, scan_result, refresh_result}

           error ->
             {season_num, error, {:ok, 0, 0}}
         end
       end)}
    end
  end

  def handle_event("rescan_movie", _params, socket) do
    media_item = socket.assigns.media_item

    if media_item.type != "movie" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for movies")}
    else
      # Start async task to re-scan the movie directory for new files AND refresh metadata
      {:noreply,
       socket
       |> put_flash(:info, "Re-scanning movie: discovering new files and refreshing metadata...")
       |> start_async(:rescan_movie, fn ->
         # Step 1: Discover new files in the directory
         scan_result = Library.rescan_movie(media_item.id)

         # Step 2: Refresh file metadata for all files (existing + new)
         case scan_result do
           {:ok, _result} ->
             # Reload the media item to get the updated file list
             updated_media_item = Media.get_media_item!(media_item.id, preload: [:media_files])
             all_media_files = updated_media_item.media_files
             refresh_result = refresh_files(all_media_files)
             {scan_result, refresh_result}

           error ->
             {error, {:ok, 0, 0}}
         end
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
    with :ok <- Authorization.authorize_update_media(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_files, false)}
  end

  def handle_event("hide_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_files, false)}
  end

  def handle_event("toggle_delete_files", %{"delete_files" => value}, socket) do
    delete_files = value == "true"

    require Logger
    Logger.info("toggle_delete_files", value: value, delete_files: delete_files)

    {:noreply, assign(socket, :delete_files, delete_files)}
  end

  def handle_event("delete_media", _params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      media_item = socket.assigns.media_item
      delete_files = socket.assigns.delete_files

      require Logger

      Logger.info("LiveView delete_media event",
        media_item_id: media_item.id,
        title: media_item.title,
        delete_files: delete_files
      )

      case Media.delete_media_item(media_item, delete_files: delete_files) do
        {:ok, _} ->
          message =
            if delete_files do
              "#{media_item.title} deleted successfully (including files)"
            else
              "#{media_item.title} removed from library (files preserved)"
            end

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> push_navigate(to: ~p"/media")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to delete #{media_item.title}")
           |> assign(:show_delete_confirm, false)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_episode_monitored", %{"episode-id" => episode_id}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      episode = Media.get_episode!(episode_id)
      {:ok, _updated_episode} = Media.update_episode(episode, %{monitored: !episode.monitored})

      {:noreply,
       socket
       |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
       |> put_flash(
         :info,
         "Episode monitoring #{if episode.monitored, do: "disabled", else: "enabled"}"
       )}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("monitor_season", %{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("unmonitor_season", %{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_season_expanded", %{"season-number" => season_number_str}, socket) do
    season_number = String.to_integer(season_number_str)
    expanded_seasons = socket.assigns.expanded_seasons

    updated_seasons =
      if MapSet.member?(expanded_seasons, season_number) do
        MapSet.delete(expanded_seasons, season_number)
      else
        MapSet.put(expanded_seasons, season_number)
      end

    {:noreply, assign(socket, :expanded_seasons, updated_seasons)}
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
    with :ok <- Authorization.authorize_delete_media(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
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

  def handle_event("show_rename_modal", _params, socket) do
    # Reload media item to ensure we have fresh file data
    media_item = load_media_item(socket.assigns.media_item.id)

    # Generate rename previews for all files
    rename_previews =
      Mydia.Library.FileRenamer.generate_rename_previews_for_media_item(media_item)

    {:noreply,
     socket
     |> assign(:show_rename_modal, true)
     |> assign(:rename_previews, rename_previews)}
  end

  def handle_event("hide_rename_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:renaming_files, false)}
  end

  def handle_event("confirm_rename_files", _params, socket) do
    rename_previews = socket.assigns.rename_previews

    # Build rename specs for batch operation
    rename_specs =
      Enum.map(rename_previews, fn preview ->
        %{file_id: preview.file_id, new_path: preview.proposed_path}
      end)

    # Start async rename operation
    {:noreply,
     socket
     |> assign(:renaming_files, true)
     |> start_async(:rename_files, fn ->
       Mydia.Library.FileRenamer.rename_files_batch(rename_specs)
     end)}
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
    with :ok <- Authorization.authorize_manage_downloads(socket) do
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
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_created, download}, socket) do
    if download_for_media?(download, socket.assigns.media_item) do
      media_item = load_media_item(socket.assigns.media_item.id)
      downloads_with_status = load_downloads_with_status(media_item)
      timeline_events = load_timeline_events(media_item)

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
    timeline_events = load_timeline_events(media_item)

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

  def handle_info({:event_created, event}, socket) do
    # Check if this event is related to the current media item
    if event.resource_type == "media_item" &&
         event.resource_id == socket.assigns.media_item.id do
      # Reload timeline events to include the new event
      timeline_events = load_timeline_events(socket.assigns.media_item)

      {:noreply, assign(socket, :timeline_events, timeline_events)}
    else
      {:noreply, socket}
    end
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

  def handle_async(:rescan_series, {:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message =
      if Enum.empty?(scan_result.errors) do
        "Re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s)"
      else
        "Re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s), #{length(scan_result.errors)} error(s)"
      end

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_async(:rescan_series, {:ok, {{:error, :not_a_tv_show}, _}}, socket) do
    {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
  end

  def handle_async(:rescan_series, {:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "No existing media files found. Please import at least one file first."
     )}
  end

  def handle_async(:rescan_series, {:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Series re-scan failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Failed to re-scan series: #{inspect(reason)}")}
  end

  def handle_async(:rescan_series, {:exit, reason}, socket) do
    Logger.error("Series re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Series re-scan failed unexpectedly")}
  end

  def handle_async(:rescan_movie, {:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message =
      if Enum.empty?(scan_result.errors) do
        "Re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s)"
      else
        "Re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s), #{length(scan_result.errors)} error(s)"
      end

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_async(:rescan_movie, {:ok, {{:error, :not_a_movie}, _}}, socket) do
    {:noreply, put_flash(socket, :error, "Re-scan is only available for movies")}
  end

  def handle_async(:rescan_movie, {:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "No existing media files found. Please import at least one file first."
     )}
  end

  def handle_async(:rescan_movie, {:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Movie re-scan failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Failed to re-scan movie: #{inspect(reason)}")}
  end

  def handle_async(:rescan_movie, {:exit, reason}, socket) do
    Logger.error("Movie re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Movie re-scan failed unexpectedly")}
  end

  def handle_async(
        :rescan_season,
        {:ok, {season_num, {:ok, scan_result}, {:ok, refreshed, _errors}}},
        socket
      ) do
    message =
      if Enum.empty?(scan_result.errors) do
        "Season #{season_num} re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s)"
      else
        "Season #{season_num} re-scan complete! Found #{scan_result.new_files} new file(s), refreshed metadata for #{refreshed} file(s), #{length(scan_result.errors)} error(s)"
      end

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> assign(:rescanning_season, nil)
     |> put_flash(:info, message)}
  end

  def handle_async(:rescan_season, {:ok, {_season_num, {:error, :not_a_tv_show}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Re-scan is only available for TV shows")}
  end

  def handle_async(:rescan_season, {:ok, {season_num, {:error, :no_media_files}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(
       :error,
       "No existing media files found for season #{season_num}. Please import at least one file first."
     )}
  end

  def handle_async(:rescan_season, {:ok, {season_num, {:error, reason}, _}}, socket) do
    Logger.error("Season #{season_num} re-scan failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Failed to re-scan season #{season_num}: #{inspect(reason)}")}
  end

  def handle_async(:rescan_season, {:exit, reason}, socket) do
    Logger.error("Season re-scan task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Season re-scan failed unexpectedly")}
  end

  def handle_async(:rename_files, {:ok, {:ok, results}}, socket) do
    # Count successes and errors
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    message =
      cond do
        error_count == 0 ->
          "Successfully renamed #{success_count} file(s)"

        success_count == 0 ->
          "Failed to rename all files"

        true ->
          "Renamed #{success_count} file(s), #{error_count} failed"
      end

    flash_type = if error_count > 0, do: :warning, else: :info

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(flash_type, message)}
  end

  def handle_async(:rename_files, {:ok, {:error, reason}}, socket) do
    Logger.error("File rename failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> put_flash(:error, "Failed to rename files: #{inspect(reason)}")}
  end

  def handle_async(:rename_files, {:exit, reason}, socket) do
    Logger.error("File rename task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> put_flash(:error, "File rename failed unexpectedly")}
  end
end
