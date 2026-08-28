defmodule MydiaWeb.MediaLive.Show.Loaders do
  @moduledoc """
  Data loading functions for the MediaLive.Show page.
  Handles loading media items, downloads, timeline events, and related data.
  """

  import Ecto.Query, warn: false

  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Events
  alias Mydia.Subtitles
  alias Mydia.Library.MediaFile
  alias MydiaWeb.MediaLive.Show.Helpers

  def load_media_item(id) do
    preload_list = build_preload_list()
    Media.get_media_item!(id, preload: preload_list)
  end

  defp build_preload_list do
    # Untrashed media files, extras included: the movie page needs to see
    # extras in order to display them, split out from versions in the
    # component. Use MediaFile.versions/0 instead wherever the caller needs
    # to pick *the* file for a media item (playback, subtitles, upgrades).
    active_files_query = MediaFile.active() |> preload(:library_path)

    [
      quality_profile: [],
      episodes: [media_files: active_files_query, downloads: :media_item],
      media_files: active_files_query,
      downloads: []
    ]
  end

  def load_downloads_with_status(media_item) do
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

  def load_timeline_events(media_item, user) do
    # Scoped by viewer: playback events record resource_type "media_item", so an
    # unscoped read would show a guest every account's watch activity here.
    events = Events.get_visible_resource_events(user, "media_item", media_item.id, limit: 50)

    # Format each event for timeline display
    events
    |> Enum.reject(&metadata_enriched_event?/1)
    |> Enum.map(fn event ->
      formatted = Events.format_for_timeline(event)

      # Merge formatted properties with event data needed by template
      Map.merge(formatted, %{
        timestamp: event.inserted_at,
        metadata: MydiaWeb.MediaLive.Show.Formatters.format_metadata_for_display(event)
      })
    end)
  end

  defp metadata_enriched_event?(%{type: "media_item.updated", metadata: %{"reason" => reason}}) do
    String.contains?(reason, "Metadata enriched")
  end

  defp metadata_enriched_event?(_event), do: false

  # Load next episode to watch for TV shows
  def load_next_episode(media_item, socket) do
    if media_item.type == "tv_show" do
      user_id = socket.assigns.current_user.id

      case Mydia.Playback.get_next_episode(media_item.id, user_id) do
        {:continue, episode} -> {episode, :continue}
        {:next, episode} -> {episode, :next}
        {:start, episode} -> {episode, :start}
        :all_watched -> {nil, :all_watched}
        nil -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  # Load transcode jobs for all media files in a media item
  # Returns a map of media_file_id => list of transcode jobs
  #
  # "original" jobs are dropped: they carry no transcoded rendition (the source
  # file is served as-is), so surfacing them would only report that someone once
  # downloaded the file.
  def load_transcode_jobs(media_item) do
    episode_files = Enum.flat_map(media_item.episodes || [], & &1.media_files)
    all_files = media_item.media_files ++ episode_files

    all_files
    |> Enum.flat_map(fn media_file ->
      Downloads.list_transcode_jobs_for_media_file(media_file.id)
    end)
    |> Enum.reject(&(&1.resolution == "original"))
    |> Enum.group_by(& &1.media_file_id)
  end

  @doc """
  Every subtitle track for every media file of a media item, with its stored
  offset and last re-sync outcome attached.

  Reads `Extractor.list_subtitle_tracks/2` rather than `Subtitles.list_subtitles/1`
  so embedded tracks appear too. Embedded tracks are where bad timing is most
  often baked in and least fixable, so hiding them is exactly backwards for a
  screen whose job is fixing timing. This reads the stored `metadata.streams`
  capture and does not shell out to ffprobe.

  Covers episode media files as well as the item's own, via
  `Helpers.all_media_files/1`: `media_item.media_files` alone is always
  empty for a TV show.

  `resync_state` is `nil` for a track that has never been auto-synced, either
  automatically or manually; the UI treats that as "nothing to report" rather
  than as a declined outcome.
  """
  def load_media_file_subtitle_tracks(media_item) do
    media_item
    |> Helpers.all_media_files()
    |> Enum.map(fn media_file ->
      offsets = Subtitles.TrackSettings.offsets_for_media_file(media_file.id)
      resync_states = Subtitles.TrackSettings.resync_states_for_media_file(media_file.id)

      tracks =
        media_file
        |> Subtitles.Extractor.list_subtitle_tracks()
        |> Enum.map(fn track ->
          ref = to_string(track.track_id)

          track
          |> Map.put(:offset_ms, Map.get(offsets, ref, 0))
          |> Map.put(:resync_state, Map.get(resync_states, ref))
        end)

      {media_file.id, tracks}
    end)
    |> Map.new()
  end

  @doc """
  Assigns the resolved target library, the reason, and the candidate list.
  """
  def assign_target_library(socket, media_item) do
    {library, reason} =
      case Mydia.Library.TargetResolver.resolve(media_item) do
        {:ok, library, reason} -> {library, reason}
        {:error, :no_compatible_library} -> {nil, nil}
      end

    media_type = if media_item.type == "movie", do: :movie, else: :tv_show

    socket
    |> Phoenix.Component.assign(:target_library, library)
    |> Phoenix.Component.assign(:target_reason, reason)
    |> Phoenix.Component.assign(
      :target_library_candidates,
      MydiaWeb.Live.Helpers.MediaAddHelpers.candidate_libraries(media_type)
    )
  end
end
