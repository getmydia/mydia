defmodule MydiaWeb.MediaLive.Show do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Settings
  alias MydiaWeb.MediaLive.Show.Modals
  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.MediaLive.Show.FranchiseComponents
  alias MydiaWeb.MediaLive.Show.EpisodeEvents
  alias MydiaWeb.MediaLive.Show.DownloadEvents
  alias MydiaWeb.MediaLive.Show.MediaItemEvents
  alias MydiaWeb.MediaLive.Show.LibraryEvents
  alias MydiaWeb.MediaLive.Show.CategoryEvents
  alias MydiaWeb.MediaLive.Show.CollectionEvents
  alias MydiaWeb.MediaLive.Show.SubtitleEvents
  alias MydiaWeb.MediaLive.Show.FileEvents
  alias MydiaWeb.MediaLive.Show.SearchEvents
  alias MydiaWeb.MediaLive.Show.SegmentEvents
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents
  alias MydiaWeb.DiscoverComponents

  # Import helper modules
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.Formatters, only: [format_progress: 1]
  import MydiaWeb.MediaLive.Show.Helpers
  import MydiaWeb.MediaLive.Show.SearchHelpers
  import MydiaWeb.MediaLive.Show.Loaders

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "events:all")
      Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")
    end

    media_item = load_media_item(id)
    quality_profiles = Settings.list_quality_profiles()

    default_quality_profile_name =
      case Settings.get_default_quality_profile() do
        nil -> nil
        profile -> profile.name
      end

    # Load downloads with real-time status
    downloads_with_status = load_downloads_with_status(media_item)

    user_preference = Mydia.Accounts.get_user_preference!(socket.assigns.current_user)

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
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_files, false)
     |> assign(:quality_profiles, quality_profiles)
     |> assign(:default_quality_profile_name, default_quality_profile_name)
     |> assign(:show_file_delete_confirm, false)
     |> assign(:file_to_delete, nil)
     |> assign(:delete_file_from_disk, true)
     |> assign(:show_file_details_modal, false)
     |> assign(:file_details, nil)
     |> assign(:show_download_cancel_confirm, false)
     |> assign(:download_to_cancel, nil)
     |> assign(:show_download_delete_confirm, false)
     |> assign(:download_to_delete, nil)
     |> assign(:show_download_details_modal, false)
     |> assign(:download_details, nil)
     # Provider re-identification picker state
     |> assign(:show_reidentify_modal, false)
     |> assign(:reidentify_candidates, [])
     |> assign(:reidentify_provider, nil)
     |> assign(:reidentifying, false)
     # Manual search modal state
     |> assign(:show_manual_search_modal, false)
     |> assign(:manual_search_query, "")
     |> assign(:manual_search_context, nil)
     |> assign(:searching, false)
     |> assign(
       :close_after_grab,
       Mydia.Accounts.UserPreference.close_manual_search_after_grab?(user_preference)
     )
     |> assign(:download_error, nil)
     |> assign(:min_seeders, 0)
     |> assign(:quality_filter, nil)
     |> assign(:sort_by, :quality)
     |> assign(:results_empty?, false)
     |> assign(:indexer_errors, [])
     |> assign(:indexer_progress, %{})
     |> assign(:search_id, 0)
     # Auto search state
     |> assign(:auto_searching, false)
     |> assign(:auto_searching_season, nil)
     |> assign(:auto_searching_episode, nil)
     # Pre-transcode state
     |> assign(:transcode_jobs, load_transcode_jobs(media_item))
     # File metadata refresh state
     |> assign(:refreshing_file_metadata, false)
     |> assign(:rescanning_season, nil)
     # File rename modal state
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:renaming_files, false)
     # Season expanded/collapsed state
     |> assign(:expanded_seasons, expanded_seasons)
     # Episode expanded/collapsed state (for showing file details)
     |> assign(:expanded_episodes, MapSet.new())
     # Next episode for TV shows
     |> assign(:next_episode, next_episode)
     |> assign(:next_episode_state, next_episode_state)
     # Subtitle state
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:subtitle_search_state, :idle)
     |> assign(:downloading_subtitle_id, nil)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_providers, [])
     |> assign(:selected_media_file, nil)
     |> assign(:selected_languages, ["en"])
     |> assign(:media_file_subtitles, load_media_file_subtitles(media_item))
     # Feature flags
     |> assign(:playback_enabled, playback_enabled?())
     # Franchise section state
     |> assign(:franchise, nil)
     |> assign(:adding_franchise_tmdb_ids, MapSet.new())
     # Recommendations rail state
     |> assign(:recommendations, [])
     |> assign(:adding_recommendation_tmdb_ids, MapSet.new())
     |> assign(:adding_recommendation_id, nil)
     |> assign(:requesting_recommendation_id, nil)
     |> assign_new(:metadata_config, fn -> Mydia.Metadata.default_relay_config() end)
     |> assign(
       :can_create_media,
       Mydia.Accounts.Authorization.can_create_media?(socket.assigns.current_user)
     )
     |> assign(:raw_search_results, [])
     # Untruncated, undeduplicated pool of every release seen so far in the
     # current manual search, keyed by download_url. Progress messages fold
     # onto this (never onto :raw_search_results, which is already truncated
     # and deduplicated) so a later, weaker duplicate can never crown itself
     # over a stronger release evicted by an earlier round's truncation. See
     # apply_indexer_progress/2 in SearchHelpers.
     |> assign(:indexer_raw_results, %{})
     # Per-row grab state (:downloading, :downloaded, :duplicate, :grab_failed)
     # keyed by download_url. The stream is rebuilt with reset: true on every
     # progress message, filter change and re-sort, and a reset drops anything
     # that only lived in the stream, so this is the assign those badges
     # actually survive in. See SearchHelpers.stream_prepared_results/2.
     |> assign(:result_states, %{})
     # Category modal state
     |> assign(:show_category_modal, false)
     |> assign(:category_form, nil)
     |> assign(:available_categories, available_categories_for(media_item.type))
     # Trailer modal state
     |> assign(:show_trailer_modal, false)
     # Collection state
     |> CollectionEvents.load_collection_data(media_item)
     |> SegmentEvents.assign_segment_status(media_item)
     |> FranchiseEvents.maybe_load()
     |> RecommendationEvents.maybe_load()
     |> assign_target_library(media_item)
     |> stream_configure(:search_results, dom_id: &generate_positioned_id/1)
     |> stream(:search_results, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_monitored", params, socket),
    do: EpisodeEvents.toggle_monitored(params, socket)

  @impl true
  def handle_event("apply_episode_monitoring", params, socket),
    do: EpisodeEvents.apply_episode_monitoring(params, socket)

  def handle_event("toggle_monitor_new_seasons", params, socket),
    do: EpisodeEvents.toggle_monitor_new_seasons(params, socket)

  def handle_event("manual_search", params, socket),
    do: SearchEvents.manual_search(params, socket)

  def handle_event("auto_search_download", params, socket),
    do: SearchEvents.auto_search_download(params, socket)

  def handle_event("refresh_metadata", params, socket),
    do: FileEvents.refresh_metadata(params, socket)

  def handle_event("select_reidentify_candidate", params, socket),
    do: FileEvents.select_reidentify_candidate(params, socket)

  def handle_event("cancel_reidentify", params, socket),
    do: FileEvents.cancel_reidentify(params, socket)

  def handle_event("refresh_all_file_metadata", params, socket),
    do: FileEvents.refresh_all_file_metadata(params, socket)

  def handle_event("rescan_season_files", params, socket),
    do: FileEvents.rescan_season_files(params, socket)

  def handle_event("rescan_series", params, socket),
    do: FileEvents.rescan_series(params, socket)

  def handle_event("rescan_season", params, socket),
    do: FileEvents.rescan_season(params, socket)

  def handle_event("rescan_movie", params, socket),
    do: FileEvents.rescan_movie(params, socket)

  def handle_event("re_analyze_segments", params, socket),
    do: SegmentEvents.re_analyze(params, socket)

  def handle_event("show_delete_confirm", params, socket),
    do: MediaItemEvents.show_delete_confirm(params, socket)

  def handle_event("hide_delete_confirm", params, socket),
    do: MediaItemEvents.hide_delete_confirm(params, socket)

  def handle_event("toggle_delete_files", params, socket),
    do: MediaItemEvents.toggle_delete_files(params, socket)

  def handle_event("delete_media", params, socket),
    do: MediaItemEvents.delete_media(params, socket)

  def handle_event("toggle_episode_monitored", params, socket),
    do: EpisodeEvents.toggle_episode_monitored(params, socket)

  def handle_event("monitor_season", params, socket),
    do: EpisodeEvents.monitor_season(params, socket)

  def handle_event("unmonitor_season", params, socket),
    do: EpisodeEvents.unmonitor_season(params, socket)

  def handle_event("toggle_season_expanded", params, socket),
    do: EpisodeEvents.toggle_season_expanded(params, socket)

  def handle_event("toggle_episode_expanded", params, socket),
    do: EpisodeEvents.toggle_episode_expanded(params, socket)

  def handle_event("search_episode", params, socket),
    do: SearchEvents.search_episode(params, socket)

  def handle_event("manual_search_season", params, socket),
    do: SearchEvents.manual_search_season(params, socket)

  def handle_event("auto_search_season", params, socket),
    do: SearchEvents.auto_search_season(params, socket)

  def handle_event("auto_search_episode", params, socket),
    do: SearchEvents.auto_search_episode(params, socket)

  def handle_event("show_file_delete_confirm", params, socket),
    do: FileEvents.show_file_delete_confirm(params, socket)

  def handle_event("hide_file_delete_confirm", params, socket),
    do: FileEvents.hide_file_delete_confirm(params, socket)

  def handle_event("toggle_file_delete_from_disk", params, socket),
    do: FileEvents.toggle_file_delete_from_disk(params, socket)

  def handle_event("delete_media_file", params, socket),
    do: FileEvents.delete_media_file(params, socket)

  def handle_event("show_file_details", params, socket),
    do: FileEvents.show_file_details(params, socket)

  def handle_event("hide_file_details", params, socket),
    do: FileEvents.hide_file_details(params, socket)

  def handle_event("pre_transcode", params, socket),
    do: FileEvents.pre_transcode(params, socket)

  def handle_event("cancel_transcode", params, socket),
    do: FileEvents.cancel_transcode(params, socket)

  def handle_event("show_rename_modal", params, socket),
    do: FileEvents.show_rename_modal(params, socket)

  def handle_event("hide_rename_modal", params, socket),
    do: FileEvents.hide_rename_modal(params, socket)

  def handle_event("confirm_rename_files", params, socket),
    do: FileEvents.confirm_rename_files(params, socket)

  def handle_event("mark_file_preferred", params, socket),
    do: FileEvents.mark_file_preferred(params, socket)

  def handle_event("retry_download", params, socket),
    do: DownloadEvents.retry_download(params, socket)

  def handle_event("show_download_cancel_confirm", params, socket),
    do: DownloadEvents.show_download_cancel_confirm(params, socket)

  def handle_event("hide_download_cancel_confirm", params, socket),
    do: DownloadEvents.hide_download_cancel_confirm(params, socket)

  def handle_event("cancel_download", params, socket),
    do: DownloadEvents.cancel_download(params, socket)

  def handle_event("show_download_delete_confirm", params, socket),
    do: DownloadEvents.show_download_delete_confirm(params, socket)

  def handle_event("hide_download_delete_confirm", params, socket),
    do: DownloadEvents.hide_download_delete_confirm(params, socket)

  def handle_event("delete_download_record", params, socket),
    do: DownloadEvents.delete_download_record(params, socket)

  def handle_event("dismiss_failed_grab", params, socket),
    do: DownloadEvents.dismiss_failed_grab(params, socket)

  def handle_event("show_download_details", params, socket),
    do: DownloadEvents.show_download_details(params, socket)

  def handle_event("hide_download_details", params, socket),
    do: DownloadEvents.hide_download_details(params, socket)

  def handle_event("close_manual_search_modal", params, socket),
    do: SearchEvents.close_manual_search_modal(params, socket)

  def handle_event("filter_search", params, socket),
    do: SearchEvents.filter_search(params, socket)

  def handle_event("sort_search", params, socket),
    do: SearchEvents.sort_search(params, socket)

  def handle_event("toggle_close_after_grab", params, socket),
    do: SearchEvents.toggle_close_after_grab(params, socket)

  def handle_event("download_from_search", params, socket),
    do: SearchEvents.download_from_search(params, socket)

  def handle_event("retry_indexer", %{"id" => indexer_id}, socket),
    do: SearchEvents.handle_retry_indexer(indexer_id, socket)

  # Subtitle events

  def handle_event("open_subtitle_search", params, socket),
    do: SubtitleEvents.open_subtitle_search(params, socket)

  def handle_event("close_subtitle_search_modal", params, socket),
    do: SubtitleEvents.close_subtitle_search_modal(params, socket)

  def handle_event("update_subtitle_languages", params, socket),
    do: SubtitleEvents.update_subtitle_languages(params, socket)

  def handle_event("clear_subtitle_languages", params, socket),
    do: SubtitleEvents.clear_subtitle_languages(params, socket)

  def handle_event("perform_subtitle_search", params, socket),
    do: SubtitleEvents.perform_subtitle_search(params, socket)

  def handle_event("download_subtitle_result", params, socket),
    do: SubtitleEvents.download_subtitle_result(params, socket)

  def handle_event("delete_subtitle", params, socket),
    do: SubtitleEvents.delete_subtitle(params, socket)

  # Category, trailer, and quality profile events

  def handle_event("show_category_modal", params, socket),
    do: CategoryEvents.show_category_modal(params, socket)

  def handle_event("hide_category_modal", params, socket),
    do: CategoryEvents.hide_category_modal(params, socket)

  def handle_event("show_trailer_modal", params, socket),
    do: CategoryEvents.show_trailer_modal(params, socket)

  def handle_event("hide_trailer_modal", params, socket),
    do: CategoryEvents.hide_trailer_modal(params, socket)

  def handle_event("validate_category", params, socket),
    do: CategoryEvents.validate_category(params, socket)

  def handle_event("save_category", params, socket),
    do: CategoryEvents.save_category(params, socket)

  def handle_event("reset_category_to_auto", params, socket),
    do: CategoryEvents.reset_category_to_auto(params, socket)

  def handle_event("update_quality_profile", params, socket),
    do: CategoryEvents.update_quality_profile(params, socket)

  def handle_event("update_target_library", params, socket),
    do: LibraryEvents.update_target_library(params, socket)

  # Collection events

  def handle_event("toggle_favorite", params, socket),
    do: CollectionEvents.toggle_favorite(params, socket)

  def handle_event("open_add_to_collection_modal", params, socket),
    do: CollectionEvents.open_add_to_collection_modal(params, socket)

  def handle_event("close_add_to_collection_modal", params, socket),
    do: CollectionEvents.close_add_to_collection_modal(params, socket)

  def handle_event("add_to_collection", params, socket),
    do: CollectionEvents.add_to_collection(params, socket)

  def handle_event("remove_from_collection", params, socket),
    do: CollectionEvents.remove_from_collection(params, socket)

  # Franchise events

  def handle_event("add_franchise_movie", params, socket),
    do: FranchiseEvents.add_franchise_movie(params, socket)

  def handle_event("request_franchise_movie", params, socket),
    do: FranchiseEvents.request_franchise_movie(params, socket)

  @impl true
  def handle_event("add_recommendation", params, socket),
    do: RecommendationEvents.add_recommendation(params, socket)

  @impl true
  def handle_event("request_recommendation", params, socket),
    do: RecommendationEvents.request_recommendation(params, socket)

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
    # Note: This is now a fallback - the search_completed broadcast should arrive first
    socket =
      if socket.assigns.auto_searching do
        socket
        |> assign(:auto_searching, false)
        |> put_flash(:warning, "Search timed out - no response from search job")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:search_completed, media_item_id, stats}, socket) do
    # Only handle if this search was for the current media item
    if media_item_id == socket.assigns.media_item.id do
      # Reset searching states
      socket =
        socket
        |> assign(:auto_searching, false)
        |> assign(:auto_searching_season, nil)
        |> assign(:auto_searching_episode, nil)

      # Build the completion message
      message = build_search_completion_message(stats)

      # Determine flash type based on results
      flash_type =
        cond do
          Map.get(stats, :error) -> :error
          stats.downloads_initiated > 0 -> :info
          stats.results_found == 0 -> :warning
          true -> :warning
        end

      {:noreply, put_flash(socket, flash_type, message)}
    else
      {:noreply, socket}
    end
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

  def handle_info({:job_updated, _job_id}, socket) do
    # Refresh transcode jobs for the current media item
    media_item = socket.assigns.media_item

    {:noreply, assign(socket, :transcode_jobs, load_transcode_jobs(media_item))}
  end

  def handle_info({:grab_completed, payload}, socket),
    do: SearchEvents.handle_grab_completed(payload, socket)

  def handle_info({:grab_failed, payload}, socket),
    do: SearchEvents.handle_grab_failed(payload, socket)

  def handle_info({:grab_duplicate, payload}, socket),
    do: SearchEvents.handle_grab_duplicate(payload, socket)

  def handle_info({:indexer_search_started, search_id, pending}, socket) do
    if search_id == socket.assigns.search_id do
      incoming = Map.new(pending, fn entry -> {entry.indexer_id, entry} end)

      # Merge rather than replace: a scoped retry's on_start message only
      # covers the indexer(s) actually being retried, so a full replace here
      # would wipe every OTHER indexer's chip (success counts, durations,
      # errors) out of indexer_progress, even though those indexers were
      # never re-searched and will never report in again this search. A
      # fresh search still resets indexer_progress to %{} before starting
      # (see SearchEvents.manual_search/2), so merge and replace are
      # equivalent there; this only changes behavior for the scoped-retry
      # case.
      progress = Map.merge(socket.assigns.indexer_progress, incoming)
      {:noreply, assign(socket, :indexer_progress, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:indexer_progress, search_id, progress}, socket) do
    if search_id == socket.assigns.search_id do
      {:noreply, apply_indexer_progress(socket, progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # handle_async dispatches to event modules

  @impl true
  def handle_async(:search, result, socket),
    do: SearchEvents.handle_search_async(result, socket)

  def handle_async({:retry, indexer_id}, result, socket),
    do: SearchEvents.handle_retry_async(indexer_id, result, socket)

  def handle_async(:refresh_files, result, socket),
    do: FileEvents.handle_refresh_files_async(result, socket)

  def handle_async(:reidentify_search, result, socket),
    do: FileEvents.handle_reidentify_search_async(result, socket)

  def handle_async(:reidentify_adopt, result, socket),
    do: FileEvents.handle_reidentify_adopt_async(result, socket)

  def handle_async(:rescan_season_files, result, socket),
    do: FileEvents.handle_rescan_season_files_async(result, socket)

  def handle_async(:rescan_series, result, socket),
    do: FileEvents.handle_rescan_series_async(result, socket)

  def handle_async(:rescan_movie, result, socket),
    do: FileEvents.handle_rescan_movie_async(result, socket)

  def handle_async(:rescan_season, result, socket),
    do: FileEvents.handle_rescan_season_async(result, socket)

  def handle_async(:rename_files, result, socket),
    do: FileEvents.handle_rename_files_async(result, socket)

  def handle_async(:subtitle_search, result, socket),
    do: SubtitleEvents.handle_subtitle_search_async(result, socket)

  def handle_async(:download_subtitle, result, socket),
    do: SubtitleEvents.handle_download_subtitle_async(result, socket)

  def handle_async(:load_franchise, result, socket),
    do: FranchiseEvents.handle_load_result(result, socket)

  def handle_async({:add_franchise_movie, tmdb_id}, result, socket),
    do: FranchiseEvents.handle_add_result(tmdb_id, result, socket)

  def handle_async(:load_recommendations, result, socket),
    do: RecommendationEvents.handle_load_result(result, socket)

  def handle_async({:add_recommendation, tmdb_id}, result, socket),
    do: RecommendationEvents.handle_add_result(tmdb_id, result, socket)

  # Private helpers

  defp build_search_completion_message(stats) do
    indexers = stats.indexers_searched
    results = stats.results_found
    picked_up = stats.downloads_initiated

    cond do
      Map.get(stats, :error) ->
        "Search failed: #{stats.error}"

      picked_up > 0 ->
        "Search complete: #{indexers} indexer(s) searched, #{results} result(s) found, #{picked_up} download(s) started"

      results > 0 ->
        "Search complete: #{indexers} indexer(s) searched, #{results} result(s) found, but none matched quality criteria"

      true ->
        "Search complete: #{indexers} indexer(s) searched, no results found"
    end
  end
end
