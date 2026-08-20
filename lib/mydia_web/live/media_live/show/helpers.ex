defmodule MydiaWeb.MediaLive.Show.Helpers do
  @moduledoc """
  General helper functions for the MediaLive.Show page.
  Handles metadata extraction, episode status, download management, and UI helpers.
  """

  alias Mydia.Media
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Library
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Metadata.Structs.Video

  require Logger

  def has_media_files?(media_item) do
    # Check if media item has any files (movie files or episode files)
    movie_files = (media_item.media_files || []) != []

    episode_files =
      case media_item.type do
        "tv_show" ->
          media_item.episodes
          |> Enum.any?(fn episode -> (episode.media_files || []) != [] end)

        _ ->
          false
      end

    movie_files || episode_files
  end

  def get_poster_url(media_item),
    do: MydiaWeb.Live.Helpers.MediaImages.poster_url(media_item)

  def get_backdrop_url(media_item) do
    case media_item.metadata do
      %MediaMetadata{backdrop_path: path} when is_binary(path) ->
        Mydia.Metadata.ImageUrl.backdrop_url(path)

      _ ->
        nil
    end
  end

  def get_media_path(media_item) do
    # For movies, check media_files directly
    # For TV shows, check episode media_files
    first_file =
      case media_item.media_files do
        [file | _] ->
          file

        _ ->
          # Try to get from episodes for TV shows
          media_item
          |> Map.get(:episodes, [])
          |> Enum.flat_map(&Map.get(&1, :media_files, []))
          |> List.first()
      end

    case first_file do
      %{library_path: %{path: lib_path}, relative_path: rel_path}
      when is_binary(lib_path) and is_binary(rel_path) ->
        # For TV shows, go up one level to show series folder (not season folder)
        folder = Path.dirname(rel_path)

        folder =
          if media_item.type == "tv_show" do
            Path.dirname(folder)
          else
            folder
          end

        Path.join(lib_path, folder)

      %{relative_path: rel_path} when is_binary(rel_path) ->
        folder = Path.dirname(rel_path)

        if media_item.type == "tv_show" do
          Path.dirname(folder)
        else
          folder
        end

      _ ->
        nil
    end
  end

  def get_overview(media_item) do
    case media_item.metadata do
      %MediaMetadata{overview: overview} when is_binary(overview) and overview != "" ->
        overview

      _ ->
        "No overview available."
    end
  end

  def get_rating(media_item) do
    case media_item.metadata do
      %MediaMetadata{vote_average: rating} when is_number(rating) ->
        Float.round(rating * 1.0, 1)

      _ ->
        nil
    end
  end

  def get_runtime(media_item) do
    case media_item.metadata do
      %MediaMetadata{runtime: runtime} when is_integer(runtime) and runtime > 0 ->
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

  def get_genres(media_item) do
    case media_item.metadata do
      %MediaMetadata{genres: genres} when is_list(genres) ->
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

  def get_cast(media_item, limit \\ 6) do
    case media_item.metadata do
      %MediaMetadata{cast: cast} when is_list(cast) ->
        cast
        |> Enum.take(limit)
        |> Enum.map(fn actor ->
          %{
            name: actor.name,
            character: actor.character,
            profile_path: actor.profile_path
          }
        end)

      _ ->
        []
    end
  end

  def get_crew(media_item) do
    case media_item.metadata do
      %MediaMetadata{crew: crew} when is_list(crew) ->
        # Get key crew members (directors, writers, producers)
        crew
        |> Enum.filter(fn member ->
          member.job in ["Director", "Writer", "Screenplay", "Executive Producer", "Producer"]
        end)
        |> Enum.uniq_by(fn member -> {member.name, member.job} end)
        |> Enum.take(6)
        |> Enum.map(fn member ->
          %{name: member.name, job: member.job}
        end)

      _ ->
        []
    end
  end

  def get_first_trailer(media_item) do
    case media_item.metadata do
      %MediaMetadata{videos: [%Video{} = video | _]} ->
        video

      _ ->
        nil
    end
  end

  def get_trailer_embed_url(media_item) do
    case get_first_trailer(media_item) do
      %Video{} = video -> Video.youtube_embed_url(video)
      _ -> nil
    end
  end

  def get_profile_image_url(nil), do: nil

  def get_profile_image_url(path) when is_binary(path) do
    Mydia.Metadata.ImageUrl.profile_url(path)
  end

  def group_episodes_by_season(episodes) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.sort_by(fn {season, _} -> season end, :desc)
  end

  @doc """
  The season(s) to expand by default on mount.

  The season of the next episode wins, so the page opens on what the user would
  actually play next. When there is no next episode — `:all_watched`, a show
  `get_next_episode/2` returns `nil` for, or a next episode whose season is not
  in the grouped list — falls back to the newest season. Non-TV shows and shows
  with no episodes expand nothing.
  """
  def default_expanded_seasons(%{type: "tv_show"} = media_item, next_episode) do
    season_numbers =
      media_item.episodes
      |> Enum.map(& &1.season_number)
      |> Enum.uniq()

    preferred =
      case next_episode do
        %{season_number: season} when is_integer(season) -> season
        _ -> nil
      end

    season =
      cond do
        preferred in season_numbers -> preferred
        season_numbers != [] -> Enum.max(season_numbers)
        true -> nil
      end

    case season do
      nil -> MapSet.new()
      season -> MapSet.new([season])
    end
  end

  def default_expanded_seasons(_media_item, _next_episode), do: MapSet.new()

  @doc """
  Counts one season's episodes by availability in a single pass.

  `available` counts `:downloaded` episodes — those with a media file. The
  `{available}/{total}` header figure and the status chip both read from this,
  so they can never disagree.
  """
  def season_episode_counts(episodes) do
    counts =
      Enum.reduce(episodes, %{available: 0, missing: 0, upcoming: 0}, fn episode, acc ->
        case get_episode_status(episode).state do
          :downloaded -> %{acc | available: acc.available + 1}
          :missing -> %{acc | missing: acc.missing + 1}
          :upcoming -> %{acc | upcoming: acc.upcoming + 1}
          _ -> acc
        end
      end)

    Map.put(counts, :total, length(episodes))
  end

  def get_episode_quality_badge(episode) do
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
  def get_episode_status(episode) do
    EpisodeStatus.get_episode_status_with_downloads(episode)
  end

  def episode_status_color(status), do: AvailabilityStatus.color(status)

  def episode_status_icon(status), do: AvailabilityStatus.icon(status)

  def episode_status_label(status), do: AvailabilityStatus.label(status)

  @doc "Human-readable label for a TV metadata provider."
  def provider_label(:tvdb), do: "TheTVDB"
  def provider_label(:tmdb), do: "TMDB"
  def provider_label(other), do: to_string(other)

  def episode_status_details(episode) do
    EpisodeStatus.status_details(episode)
  end

  @doc """
  Returns an enhanced tooltip for episode status that includes filenames for quick reference.
  """
  def episode_status_tooltip(episode) do
    base_status = EpisodeStatus.status_details(episode)

    case episode.media_files do
      [_ | _] = files ->
        filenames =
          Enum.map_join(files, "\n", fn file ->
            basename = Mydia.Library.MediaFile.display_name(file)
            resolution = file.resolution || "?"
            "• #{basename} (#{resolution})"
          end)

        "#{base_status}\n\nFiles:\n#{filenames}"

      _ ->
        base_status
    end
  end

  @in_client_active_statuses ["downloading", "seeding", "checking", "paused"]

  # Header status pick, in priority order: a live in-client download, then a
  # grab in flight, then a failed grab (a failure that never reached a client
  # — client-side failures have their own surfaces on the Downloads page).
  def get_download_status(downloads_with_status) do
    Enum.find(downloads_with_status, &(&1.status in @in_client_active_statuses)) ||
      Enum.find(downloads_with_status, &(&1.status == "grabbing")) ||
      Enum.find(downloads_with_status, &failed_grab?/1)
  end

  defp failed_grab?(download) do
    download.status == "failed" and is_nil(download.download_client_id)
  end

  # Auto search helper functions

  def can_auto_search?(%Media.MediaItem{} = media_item, _downloads_with_status) do
    # Always allow auto search for supported media types
    # Users should be able to re-search even if files exist or downloads are in history
    media_item.type in ["movie", "tv_show"]
  end

  def has_active_download?(downloads_with_status) do
    Enum.any?(downloads_with_status, fn d ->
      d.status in ["downloading", "checking"]
    end)
  end

  def episode_in_season?(episode_id, season_num) do
    episode = Media.get_episode!(episode_id)
    episode.season_number == season_num
  end

  # Helper to get all media files for episodes in a specific season
  def get_season_media_files(media_item, season_number) do
    media_item.episodes
    |> Enum.filter(&(&1.season_number == season_number))
    |> Enum.flat_map(& &1.media_files)
  end

  # File metadata refresh helper
  def refresh_files(media_files) do
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

  # Get button text based on watch state
  def next_episode_button_text(:continue), do: "Continue Watching"
  def next_episode_button_text(:next), do: "Play Next Episode"
  def next_episode_button_text(:start), do: "Start Watching"
  def next_episode_button_text(_), do: "Play"

  # Get episode thumbnail from metadata
  def get_episode_thumbnail(episode) do
    case episode.metadata do
      %{"still_path" => path} when is_binary(path) ->
        Mydia.Metadata.ImageUrl.still_url(path)

      _ ->
        nil
    end
  end

  # Check if playback feature is enabled
  def playback_enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:playback_enabled, false)
  end

  @doc """
  Builds a URL for the Flutter player.

  The Flutter player is served at `/player/` with hash-based routing.
  The player route pattern is: `/player/#/player/:type/:id?fileId=...&title=...`

  Note: The trailing slash before `#` is required for Flutter web hash routing
  to work correctly with the base-href configuration.

  ## Parameters
    - type: "movie" or "episode"
    - id: The media item or episode ID
    - opts: Keyword list with optional parameters:
      - file_id: The media file ID to play (required by the Flutter player)
      - title: Display title for the player

  ## Examples
      flutter_player_url("movie", media_item.id, file_id: file.id, title: "Movie Title")
      flutter_player_url("episode", episode.id, file_id: file.id)
  """
  def flutter_player_url(type, id, opts \\ []) do
    file_id = Keyword.get(opts, :file_id)
    title = Keyword.get(opts, :title)

    query_params =
      []
      |> then(fn params -> if file_id, do: [{"fileId", file_id} | params], else: params end)
      |> then(fn params -> if title, do: [{"title", title} | params], else: params end)

    query_string =
      case query_params do
        [] -> ""
        params -> "?" <> URI.encode_query(params)
      end

    # Trailing slash before # is required for Flutter web hash routing
    "/player/#/player/#{type}/#{id}#{query_string}"
  end

  @doc """
  Gets the best file to play from a list of media files.
  Prefers files with higher resolution.
  """
  def get_best_media_file([]), do: nil

  def get_best_media_file(files) do
    files
    |> Enum.sort_by(
      fn file ->
        resolution_priority(file.resolution)
      end,
      :desc
    )
    |> List.first()
  end

  defp resolution_priority(nil), do: 0
  defp resolution_priority("480p"), do: 1
  defp resolution_priority("720p"), do: 2
  defp resolution_priority("1080p"), do: 3
  defp resolution_priority("2160p"), do: 4
  defp resolution_priority("4K"), do: 4
  defp resolution_priority(_), do: 0

  def download_for_media?(download, media_item) do
    download.media_item_id == media_item.id or
      (download.episode_id &&
         Enum.any?(media_item.episodes, fn ep -> ep.id == download.episode_id end))
  end

  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Builds a URL for the Flutter player queue playback.

  The Flutter player queue route pattern is: `/player#/player/queue?items=<base64>`

  ## Parameters
    - items: List of maps with :type, :id, :file_id, :title keys
             Each item represents a playable media item in the queue

  ## Examples
      items = [
        %{type: "movie", id: "abc", file_id: "f1", title: "Movie 1"},
        %{type: "episode", id: "def", file_id: "f2", title: "S01E01 - Pilot"}
      ]
      flutter_queue_player_url(items)
  """
  def flutter_queue_player_url([]), do: nil

  def flutter_queue_player_url(items) when is_list(items) do
    # Encode the queue as base64 JSON to keep URL clean
    queue_json = Jason.encode!(items)
    queue_encoded = Base.url_encode64(queue_json)

    "/player#/player/queue?items=#{queue_encoded}"
  end

  def parse_int(value) when is_integer(value), do: value

  def parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  def parse_int(_), do: 0

  # Parse optional integer (returns nil if not present or invalid)
  def parse_optional_int(nil), do: nil
  def parse_optional_int(""), do: nil
  def parse_optional_int(value) when is_integer(value), do: value

  def parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  def parse_optional_int(_), do: nil

  # Parse optional float (returns nil if not present or invalid)
  def parse_optional_float(nil), do: nil
  def parse_optional_float(""), do: nil
  def parse_optional_float(value) when is_float(value), do: value

  def parse_optional_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  def parse_optional_float(_), do: nil

  # Available categories by media type
  def available_categories_for("movie") do
    [
      {"Movie", "movie"},
      {"Anime Movie", "anime_movie"},
      {"Cartoon Movie", "cartoon_movie"}
    ]
  end

  def available_categories_for("tv_show") do
    [
      {"TV Show", "tv_show"},
      {"Anime Series", "anime_series"},
      {"Cartoon Series", "cartoon_series"}
    ]
  end

  def available_categories_for(_), do: []

  # Navigation paths by media type
  def media_type_path("movie"), do: "/movies"
  def media_type_path("tv_show"), do: "/tv"
  def media_type_path(_), do: "/"

  # Monitoring preset labels (shared between events and components)
  def monitoring_preset_label(:all), do: "All Episodes"
  def monitoring_preset_label(:missing), do: "Missing Episodes"
  def monitoring_preset_label(:existing), do: "Existing Episodes"
  def monitoring_preset_label(:future), do: "Future Episodes"
  def monitoring_preset_label(:none), do: "No Episodes"
  # Not a preset anyone can pick: what the episodes read as once they no longer
  # match any of them, usually because a season or episode was toggled by hand.
  def monitoring_preset_label(:custom), do: "Custom"

  # Season monitoring toggle tooltips, keyed on the season's derived state
  def season_monitoring_tooltip(:all), do: "Unmonitor season"
  def season_monitoring_tooltip(:partial), do: "Monitor all episodes"
  def season_monitoring_tooltip(:none), do: "Monitor season"

  # Above this many episodes in one season, the list is split into labelled
  # ranges. TVDB's official ordering puts 170 episodes of Black Clover in a
  # single season, and long-running anime is not the only case: TVDB season 0
  # accumulates every promo and recap, which is 113 entries on Rick and Morty.
  @chunk_threshold 50
  @chunk_size 50

  @doc """
  Groups a season's episodes into labelled ranges for rendering.

  Returns `[{label, episodes}]` newest first. A season at or below the
  threshold returns a single `{nil, episodes}` chunk so callers can render it
  without a disclosure wrapper.
  """
  @spec episode_chunks([Mydia.Media.Episode.t()]) ::
          [{String.t() | nil, [Mydia.Media.Episode.t()]}]
  def episode_chunks(episodes) when is_list(episodes) do
    sorted = Enum.sort_by(episodes, & &1.episode_number, :desc)

    if length(sorted) <= @chunk_threshold do
      [{nil, sorted}]
    else
      sorted
      |> Enum.group_by(&chunk_index/1)
      |> Enum.sort_by(fn {index, _eps} -> index end, :desc)
      |> Enum.map(fn {index, eps} ->
        {chunk_label(index, eps), Enum.sort_by(eps, & &1.episode_number, :desc)}
      end)
    end
  end

  defp chunk_index(%{episode_number: number}) when is_integer(number),
    do: div(number - 1, @chunk_size)

  # An episode with no number has no place on the grid. `validate_required/2`
  # and a NOT NULL column mean no persisted row reaches here, but the `sort_by`
  # above tolerates nil and `div(nil - 1, _)` does not, so the two disagreed
  # about the same input. Group them with the first chunk rather than raising:
  # dropping the row would hide an episode the season really has.
  defp chunk_index(_episode), do: 0

  # Both bounds read off the episodes the chunk actually holds. Deriving the
  # lower bound from the grid instead (`index * @chunk_size + 1`) labels a
  # season whose episodes start at 25 "1-50", promising 24 episodes that do not
  # exist. The grid is only the fallback for a chunk with no numbers to read.
  defp chunk_label(index, eps) do
    case eps |> Enum.map(& &1.episode_number) |> Enum.reject(&is_nil/1) do
      [] -> "#{index * @chunk_size + 1}-#{(index + 1) * @chunk_size}"
      numbers -> "#{Enum.min(numbers)}-#{Enum.max(numbers)}"
    end
  end
end
