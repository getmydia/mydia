defmodule Mydia.Jobs.TVShowSearch do
  @moduledoc """
  Background job for searching and downloading TV show episode releases.

  This job searches indexers for TV show episodes and season packs, intelligently
  deciding when to download full seasons vs individual episodes. Supports both
  background execution for all monitored episodes and UI-triggered searches.

  ## Execution Modes

  - `"specific"` - Search single episode by ID (UI: "Search Episode" button)
  - `"season"` - Search full season, prefer season pack (UI: "Download Season" button)
  - `"show"` - Search all episodes for a show with smart season pack logic (UI: "Auto Search Show")
  - `"all_monitored"` - Search all monitored episodes with smart logic (scheduled)

  ## Season Pack Logic

  For "show" and "all_monitored" modes, episodes are grouped by season and the job
  decides whether to download season packs or individual episodes:

  - If >= 70% of season episodes are missing → prefer season pack
  - If < 70% of season episodes are missing → download individual episodes only

  ## Examples

      # Queue a search for all monitored episodes
      %{mode: "all_monitored"}
      |> TVShowSearch.new()
      |> Oban.insert()

      # Queue a search for a specific episode
      %{mode: "specific", episode_id: "episode-uuid"}
      |> TVShowSearch.new()
      |> Oban.insert()

      # Queue a search for a full season (always prefer season pack)
      %{mode: "season", media_item_id: "show-uuid", season_number: 1}
      |> TVShowSearch.new()
      |> Oban.insert()

      # Queue a search for all episodes of a show (smart logic)
      %{mode: "show", media_item_id: "show-uuid"}
      |> TVShowSearch.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Repo, Media, Indexers, Downloads}
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Media.{MediaItem, Episode}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "specific", "episode_id" => episode_id} = args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting search for specific episode", episode_id: episode_id)

    result =
      try do
        episode = load_episode(episode_id)

        case episode do
          %Episode{} ->
            search_episode(episode, args)

          nil ->
            Logger.error("Episode not found", episode_id: episode_id)
            {:error, :not_found}
        end
      rescue
        Ecto.NoResultsError ->
          Logger.error("Episode not found", episode_id: episode_id)
          {:error, :not_found}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Episode search completed",
          duration_ms: duration,
          episode_id: episode_id
        )

        :ok

      :no_results ->
        Logger.info("Episode search completed with no results",
          duration_ms: duration,
          episode_id: episode_id
        )

        :no_results

      {:error, reason} ->
        Logger.error("Episode search failed",
          error: inspect(reason),
          duration_ms: duration,
          episode_id: episode_id
        )

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "mode" => "season",
            "media_item_id" => media_item_id,
            "season_number" => season_number
          } =
            args
      }) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting search for full season",
      media_item_id: media_item_id,
      season_number: season_number
    )

    result =
      try do
        media_item = Media.get_media_item!(media_item_id)

        case media_item do
          %MediaItem{type: "tv_show"} ->
            episodes = load_episodes_for_season(media_item_id, season_number)

            if episodes == [] do
              Logger.info("No missing episodes found for season",
                media_item_id: media_item_id,
                season_number: season_number
              )

              :ok
            else
              search_season(media_item, season_number, episodes, args)
            end

          %MediaItem{type: type} ->
            Logger.error("Invalid media type for TV show search",
              media_item_id: media_item_id,
              type: type
            )

            {:error, :invalid_type}
        end
      rescue
        Ecto.NoResultsError ->
          Logger.error("Media item not found", media_item_id: media_item_id)
          {:error, :not_found}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Season search completed",
          duration_ms: duration,
          media_item_id: media_item_id,
          season_number: season_number
        )

        :ok

      :no_results ->
        Logger.info("Season search completed with no results",
          duration_ms: duration,
          media_item_id: media_item_id,
          season_number: season_number
        )

        :no_results

      {:error, reason} ->
        Logger.error("Season search failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id,
          season_number: season_number
        )

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "show", "media_item_id" => media_item_id} = args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting search for all episodes of show", media_item_id: media_item_id)

    result =
      try do
        media_item = Media.get_media_item!(media_item_id)

        case media_item do
          %MediaItem{type: "tv_show"} ->
            episodes = load_episodes_for_show(media_item_id)

            if episodes == [] do
              Logger.info("No missing episodes found for show",
                media_item_id: media_item_id,
                title: media_item.title
              )

              :ok
            else
              process_episodes_with_smart_logic(media_item, episodes, args)
            end

          %MediaItem{type: type} ->
            Logger.error("Invalid media type for TV show search",
              media_item_id: media_item_id,
              type: type
            )

            {:error, :invalid_type}
        end
      rescue
        Ecto.NoResultsError ->
          Logger.error("Media item not found", media_item_id: media_item_id)
          {:error, :not_found}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Show search completed",
          duration_ms: duration,
          media_item_id: media_item_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Show search failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_monitored"} = args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting automatic search for all monitored episodes")

    episodes = load_monitored_episodes_without_files()
    total_count = length(episodes)

    Logger.info("Found #{total_count} monitored episodes without files")

    if total_count == 0 do
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("No episodes to search", duration_ms: duration)

      :ok
    else
      # Group by media_item for processing
      episodes_by_show =
        episodes
        |> Enum.group_by(& &1.media_item_id)

      show_count = map_size(episodes_by_show)
      Logger.info("Grouped episodes into #{show_count} shows")

      # Process each show
      Enum.each(episodes_by_show, fn {media_item_id, show_episodes} ->
        media_item = hd(show_episodes).media_item

        Logger.info("Processing show",
          media_item_id: media_item_id,
          title: media_item.title,
          episodes: length(show_episodes)
        )

        process_episodes_with_smart_logic(media_item, show_episodes, args)
      end)

      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Automatic episode search completed",
        duration_ms: duration,
        total_episodes: total_count,
        shows_processed: show_count
      )

      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => mode}}) do
    Logger.error("Unsupported mode", mode: mode)
    {:error, :unsupported_mode}
  end

  ## Private Functions - Episode Loading

  defp load_episode(episode_id) do
    Episode
    |> where([e], e.id == ^episode_id)
    |> preload(:media_item)
    |> Repo.one()
  end

  defp load_monitored_episodes_without_files do
    today = Date.utc_today()

    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e], e.air_date <= ^today)
    |> join(:left, [e], mf in assoc(e, :media_files))
    |> group_by([e], e.id)
    |> having([_e, _m, mf], count(mf.id) == 0)
    |> preload(:media_item)
    |> Repo.all()
  end

  defp load_episodes_for_show(media_item_id) do
    today = Date.utc_today()

    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.media_item_id == ^media_item_id)
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e], e.air_date <= ^today)
    |> join(:left, [e], mf in assoc(e, :media_files))
    |> group_by([e], e.id)
    |> having([_e, _m, mf], count(mf.id) == 0)
    |> preload(:media_item)
    |> Repo.all()
  end

  defp load_episodes_for_season(media_item_id, season_number) do
    today = Date.utc_today()

    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e], e.air_date <= ^today)
    |> join(:left, [e], mf in assoc(e, :media_files))
    |> group_by([e], e.id)
    |> having([_e, _m, mf], count(mf.id) == 0)
    |> preload(:media_item)
    |> Repo.all()
  end

  ## Private Functions - Query Construction

  defp build_episode_query(%Episode{media_item: media_item} = episode) do
    show_title = media_item.title
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    ep_num = String.pad_leading("#{episode.episode_number}", 2, "0")

    "#{show_title} S#{season}E#{ep_num}"
  end

  defp build_season_query(%MediaItem{} = media_item, season_number) do
    show_title = media_item.title
    season = String.pad_leading("#{season_number}", 2, "0")

    "#{show_title} S#{season}"
  end

  ## Private Functions - Smart Episode Processing

  defp process_episodes_with_smart_logic(media_item, episodes, args) do
    Logger.info("Processing episodes with smart season pack logic",
      media_item_id: media_item.id,
      title: media_item.title,
      total_episodes: length(episodes)
    )

    # Group episodes by season
    episodes_by_season = Enum.group_by(episodes, & &1.season_number)

    Logger.info("Grouped episodes into #{map_size(episodes_by_season)} seasons")

    # Process each season independently
    Enum.each(episodes_by_season, fn {season_number, season_episodes} ->
      Logger.info("Processing season",
        media_item_id: media_item.id,
        title: media_item.title,
        season_number: season_number,
        missing_episodes: length(season_episodes)
      )

      # Determine if we should prefer season pack
      if should_prefer_season_pack?(season_episodes, media_item, season_number) do
        Logger.info("70% threshold met - preferring season pack",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          missing_episodes: length(season_episodes)
        )

        # Try season pack first
        search_season(media_item, season_number, season_episodes, args)
      else
        Logger.info("Below 70% threshold - downloading individual episodes",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          missing_episodes: length(season_episodes)
        )

        # Download individual episodes
        search_individual_episodes(season_episodes, args)
      end
    end)

    :ok
  end

  defp should_prefer_season_pack?(missing_episodes, media_item, season_number) do
    missing_count = length(missing_episodes)

    # Try to get total episode count from metadata
    total_count =
      case get_total_episodes_for_season(media_item, season_number) do
        nil ->
          # Fallback: assume missing episodes represent all episodes
          # This happens when metadata doesn't have episode counts
          missing_count

        count when count > 0 ->
          count

        _ ->
          missing_count
      end

    missing_percentage = missing_count / total_count * 100

    Logger.debug("Season pack threshold calculation",
      media_item_id: media_item.id,
      season_number: season_number,
      missing_count: missing_count,
      total_count: total_count,
      missing_percentage: Float.round(missing_percentage, 1)
    )

    # Use 70% threshold
    missing_percentage >= 70.0
  end

  defp get_total_episodes_for_season(media_item, season_number) do
    # Try to get episode count from metadata
    case media_item.metadata do
      %{"seasons" => seasons} when is_list(seasons) ->
        Enum.find_value(seasons, fn season ->
          if season["season_number"] == season_number do
            season["episode_count"]
          end
        end)

      _ ->
        nil
    end
  end

  ## Private Functions - Season Search Logic

  defp search_season(media_item, season_number, episodes, args) do
    Logger.info("Searching for season pack",
      media_item_id: media_item.id,
      title: media_item.title,
      season_number: season_number,
      missing_episodes: length(episodes)
    )

    # For "season" mode, always prefer season pack
    # Try season pack first, fall back to individual episodes
    query = build_season_query(media_item, season_number)

    Logger.info("Searching for season pack",
      media_item_id: media_item.id,
      title: media_item.title,
      season_number: season_number,
      query: query
    )

    case Indexers.search_all(query, min_seeders: 3) do
      {:ok, []} ->
        Logger.warning("No season pack results found, falling back to individual episodes",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number
        )

        # Fall back to searching individual episodes
        search_individual_episodes(episodes, args)

      {:ok, results} ->
        Logger.info("Found #{length(results)} season pack results",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number
        )

        # Filter for actual season packs (no episode markers)
        season_pack_results = filter_season_packs(results, season_number)

        if season_pack_results == [] do
          Logger.warning(
            "No valid season packs after filtering, falling back to individual episodes",
            media_item_id: media_item.id,
            title: media_item.title,
            season_number: season_number,
            total_results: length(results)
          )

          search_individual_episodes(episodes, args)
        else
          process_season_pack_results(
            media_item,
            season_number,
            episodes,
            season_pack_results,
            args
          )
        end
    end
  end

  defp filter_season_packs(results, season_number) do
    season_marker = "S#{String.pad_leading("#{season_number}", 2, "0")}"
    episode_marker_regex = ~r/E\d{2}/i

    Enum.filter(results, fn result ->
      title_upper = String.upcase(result.title)

      # Must contain the season marker and NOT contain any episode markers
      String.contains?(title_upper, season_marker) and
        not Regex.match?(episode_marker_regex, title_upper)
    end)
  end

  defp process_season_pack_results(media_item, season_number, episodes, results, args) do
    # Build ranking options from the first episode (they all share the same show)
    ranking_opts = build_ranking_options_for_season(media_item, episodes, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning(
          "No suitable season pack after ranking, falling back to individual episodes",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          total_results: length(results)
        )

        search_individual_episodes(episodes, args)

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best season pack",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown,
          episodes_count: length(episodes)
        )

        initiate_season_pack_download(media_item, season_number, episodes, best_result)
    end
  end

  defp search_individual_episodes(episodes, args) do
    Logger.info("Searching for #{length(episodes)} individual episodes")

    results = Enum.map(episodes, &search_episode(&1, args))

    successful = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Individual episode search completed",
      total: length(episodes),
      successful: successful,
      failed: failed
    )

    :ok
  end

  ## Private Functions - Search Logic

  defp search_episode(%Episode{} = episode, args) do
    # Skip if episode already has files
    if has_media_files?(episode) do
      Logger.debug("Episode already has files, skipping",
        episode_id: episode.id,
        season: episode.season_number,
        episode: episode.episode_number
      )

      :ok
    else
      # Skip if episode hasn't aired yet
      if future_episode?(episode) do
        Logger.debug("Episode has future air date, skipping",
          episode_id: episode.id,
          season: episode.season_number,
          episode: episode.episode_number,
          air_date: episode.air_date
        )

        :ok
      else
        perform_episode_search(episode, args)
      end
    end
  end

  defp perform_episode_search(%Episode{} = episode, args) do
    query = build_episode_query(episode)

    Logger.info("Searching for episode",
      episode_id: episode.id,
      show: episode.media_item.title,
      season: episode.season_number,
      episode: episode.episode_number,
      query: query
    )

    case Indexers.search_all(query, min_seeders: 3) do
      {:ok, []} ->
        Logger.warning("No results found for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          query: query
        )

        :ok

      {:ok, results} ->
        Logger.info("Found #{length(results)} results for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number
        )

        process_episode_results(episode, results, args)
    end
  end

  defp process_episode_results(episode, results, args) do
    ranking_opts = build_ranking_options(episode, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning("No suitable results after ranking for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          total_results: length(results)
        )

        :ok

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best result for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown
        )

        initiate_episode_download(episode, best_result)
    end
  end

  ## Private Functions - Quality & Ranking

  defp build_ranking_options(episode, args) do
    # Start with base options - TV shows typically have smaller file sizes than movies
    base_opts = [
      min_seeders: Map.get(args, "min_seeders", 3),
      size_range: Map.get(args, "size_range", {100, 5_000})
    ]

    # Add quality profile preferences if available
    opts_with_quality =
      case load_quality_profile(episode) do
        nil ->
          base_opts

        quality_profile ->
          Keyword.merge(base_opts, build_quality_options(quality_profile))
      end

    # Add any custom blocked/preferred tags from args
    opts_with_quality
    |> maybe_add_option(:blocked_tags, Map.get(args, "blocked_tags"))
    |> maybe_add_option(:preferred_tags, Map.get(args, "preferred_tags"))
  end

  defp build_ranking_options_for_season(media_item, _episodes, args) do
    # Season packs are typically much larger than individual episodes
    # A full season in HD can be 10-50GB depending on episode count and quality
    base_opts = [
      min_seeders: Map.get(args, "min_seeders", 3),
      size_range: Map.get(args, "size_range", {2_000, 100_000})
    ]

    # Load quality profile from media_item
    opts_with_quality =
      case media_item.quality_profile_id do
        nil ->
          base_opts

        _id ->
          quality_profile =
            media_item
            |> Repo.preload(:quality_profile)
            |> Map.get(:quality_profile)

          case quality_profile do
            nil -> base_opts
            qp -> Keyword.merge(base_opts, build_quality_options(qp))
          end
      end

    # Add any custom blocked/preferred tags from args
    opts_with_quality
    |> maybe_add_option(:blocked_tags, Map.get(args, "blocked_tags"))
    |> maybe_add_option(:preferred_tags, Map.get(args, "preferred_tags"))
  end

  defp load_quality_profile(%Episode{media_item: media_item}) do
    case media_item.quality_profile_id do
      nil ->
        nil

      _id ->
        media_item
        |> Repo.preload(:quality_profile)
        |> Map.get(:quality_profile)
    end
  end

  defp build_quality_options(quality_profile) do
    # Extract preferred qualities from quality profile
    case Map.get(quality_profile, :allowed_qualities) do
      nil -> []
      qualities when is_list(qualities) -> [preferred_qualities: qualities]
      _ -> []
    end
  end

  defp maybe_add_option(opts, _key, nil), do: opts
  defp maybe_add_option(opts, _key, []), do: opts
  defp maybe_add_option(opts, key, value), do: Keyword.put(opts, key, value)

  ## Private Functions - Download Initiation

  defp initiate_episode_download(episode, result) do
    case Downloads.initiate_download(result,
           media_item_id: episode.media_item_id,
           episode_id: episode.id
         ) do
      {:ok, download} ->
        Logger.info("Successfully initiated download for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          download_id: download.id,
          result_title: result.title
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to initiate download for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp initiate_season_pack_download(media_item, season_number, episodes, result) do
    # For season packs, we create a single download associated with the media_item
    # The download will include metadata about the season pack
    # The import job will later match files to individual episodes

    # Build metadata with season pack information
    metadata = %{
      season_pack: true,
      season_number: season_number,
      episode_count: length(episodes),
      episode_ids: Enum.map(episodes, & &1.id)
    }

    # Add metadata to the result
    result_with_metadata = Map.put(result, :metadata, metadata)

    case Downloads.initiate_download(result_with_metadata, media_item_id: media_item.id) do
      {:ok, download} ->
        Logger.info("Successfully initiated season pack download",
          media_item_id: media_item.id,
          show: media_item.title,
          season_number: season_number,
          episode_count: length(episodes),
          download_id: download.id,
          result_title: result.title
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to initiate season pack download",
          media_item_id: media_item.id,
          show: media_item.title,
          season_number: season_number,
          episode_count: length(episodes),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions - Helpers

  defp has_media_files?(%Episode{} = episode) do
    episode = Repo.preload(episode, :media_files, force: true)
    length(episode.media_files) > 0
  end

  defp future_episode?(%Episode{air_date: nil}), do: false

  defp future_episode?(%Episode{air_date: air_date}) do
    Date.compare(air_date, Date.utc_today()) == :gt
  end
end
