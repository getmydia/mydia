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

  alias Mydia.{Repo, Media, Indexers, Downloads, Events, Search}
  alias Mydia.Downloads.{Blacklists, Download}
  alias Mydia.Indexers.RankingOptions
  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias Mydia.Media.{MediaItem, Episode}
  alias Mydia.Library.MediaFile
  alias Phoenix.PubSub

  defmodule Args do
    @moduledoc false
    defstruct [
      :mode,
      :episode_id,
      :media_item_id,
      :season_number,
      :min_seeders,
      :size_range,
      :blocked_tags,
      :preferred_tags
    ]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            episode_id: String.t() | nil,
            media_item_id: String.t() | nil,
            season_number: integer() | nil,
            min_seeders: integer() | nil,
            size_range: term() | nil,
            blocked_tags: [String.t()] | nil,
            preferred_tags: [String.t()] | nil
          }

    def parse(%{"mode" => "specific", "episode_id" => episode_id} = raw) do
      %__MODULE__{
        mode: "specific",
        episode_id: episode_id,
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
    end

    def parse(
          %{
            "mode" => "season",
            "media_item_id" => media_item_id,
            "season_number" => season_number
          } = raw
        ) do
      %__MODULE__{
        mode: "season",
        media_item_id: media_item_id,
        season_number: season_number,
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
    end

    def parse(%{"mode" => "show", "media_item_id" => media_item_id} = raw) do
      %__MODULE__{
        mode: "show",
        media_item_id: media_item_id,
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
    end

    def parse(%{"mode" => "all_monitored"} = raw) do
      %__MODULE__{
        mode: "all_monitored",
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
    end

    def parse(%{"mode" => mode}) do
      %__MODULE__{mode: mode}
    end
  end

  # Get min_seeders from config (defaults to 0 for Usenet compatibility)
  defp get_min_seeders do
    Application.get_env(:mydia, :auto_search, [])[:min_seeders] || 0
  end

  # Merge user-supplied job-arg blocked_tags with the globally configured
  # blocked_release_tokens so language/dub tokens applied via config flow
  # into every auto-search without callers having to pass them.
  defp merged_blocked_tags(args_blocked) do
    config_tokens = Application.get_env(:mydia, :auto_search, [])[:blocked_release_tokens] || []

    case (args_blocked || []) ++ config_tokens do
      [] -> nil
      tags -> Enum.uniq(tags)
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "specific", "episode_id" => _} = raw_args}) do
    args = Args.parse(raw_args)
    episode_id = args.episode_id
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
  def perform(%Oban.Job{args: %{"mode" => "season"} = raw_args}) do
    args = Args.parse(raw_args)
    media_item_id = args.media_item_id
    season_number = args.season_number
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
              # For "season" mode, start with counter at 0
              search_season(media_item, season_number, episodes, 0, args)
              :ok
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
  def perform(%Oban.Job{args: %{"mode" => "show"} = raw_args}) do
    args = Args.parse(raw_args)
    media_item_id = args.media_item_id
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

              {:ok,
               %{
                 indexers_searched: count_enabled_indexers(),
                 results_found: 0,
                 downloads_initiated: 0
               }}
            else
              # For "show" mode, start with counter at 0 and track stats
              indexers_count = count_enabled_indexers()

              {_search_count, stats} =
                process_episodes_with_smart_logic_and_stats(
                  media_item,
                  episodes,
                  0,
                  args,
                  %{results_found: 0, downloads_initiated: 0}
                )

              {:ok, Map.put(stats, :indexers_searched, indexers_count)}
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
      {:ok, stats} ->
        Logger.info("Show search completed",
          duration_ms: duration,
          media_item_id: media_item_id,
          stats: stats
        )

        # Broadcast search completion for UI feedback
        broadcast_search_completed(media_item_id, stats)

        :ok

      {:error, reason} ->
        Logger.error("Show search failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        # Broadcast failure for UI feedback
        broadcast_search_completed(media_item_id, %{
          indexers_searched: 0,
          results_found: 0,
          downloads_initiated: 0,
          error: inspect(reason)
        })

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_monitored"} = raw_args}) do
    args = Args.parse(raw_args)
    start_time = System.monotonic_time(:millisecond)
    max_searches = get_max_searches_per_run()

    Logger.info("Starting automatic search for all monitored episodes",
      max_searches_per_run: max_searches
    )

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

      # Process each show with search counter tracking
      {final_count, shows_processed, shows_skipped} =
        Enum.reduce_while(episodes_by_show, {0, 0, 0}, fn {media_item_id, show_episodes},
                                                          {search_count, processed, skipped} ->
          if limit_reached?(search_count, max_searches) do
            Logger.warning("Global search limit reached, stopping execution",
              searches_performed: search_count,
              max_searches_per_run: max_searches,
              shows_processed: processed,
              shows_remaining: show_count - processed
            )

            {:halt, {search_count, processed, skipped + 1}}
          else
            media_item = hd(show_episodes).media_item

            Logger.info("Processing show",
              media_item_id: media_item_id,
              title: media_item.title,
              episodes: length(show_episodes),
              searches_so_far: search_count,
              searches_remaining:
                if(max_searches == :infinity, do: :infinity, else: max_searches - search_count)
            )

            new_search_count =
              process_episodes_with_smart_logic(media_item, show_episodes, search_count, args)

            {:cont, {new_search_count, processed + 1, skipped}}
          end
        end)

      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Automatic episode search completed",
        duration_ms: duration,
        total_episodes: total_count,
        shows_processed: shows_processed,
        shows_skipped: shows_skipped,
        searches_performed: final_count,
        max_searches_per_run: max_searches
      )

      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => _} = raw_args}) do
    args = Args.parse(raw_args)
    Logger.error("Unsupported mode", mode: args.mode)
    {:error, :unsupported_mode}
  end

  ## Private Functions - Episode Loading

  defp load_episode(episode_id) do
    Episode
    |> where([e], e.id == ^episode_id)
    |> preload(:media_item)
    |> Repo.one()
  end

  @doc false
  # Public for direct testing of the search-selection filter.
  def load_monitored_episodes_without_files do
    today = Date.utc_today()

    episodes =
      Episode
      |> join(:inner, [e], m in assoc(e, :media_item))
      |> where([e, m], e.monitored == true and m.monitored == true)
      |> where([e], e.air_date <= ^today)
      |> where([e], e.id not in subquery(active_episode_download_ids()))
      |> join(:left, [e], mf in MediaFile, on: mf.episode_id == e.id and is_nil(mf.trashed_at))
      |> group_by([e], e.id)
      |> having([_e, _m, mf], count(mf.id) == 0)
      |> preload(:media_item)
      |> Repo.all()

    # Filter out special episodes (S00) unless configured to monitor them
    episodes
    |> reject_episodes_in_active_season_packs()
    |> filter_special_episodes()
    |> filter_episodes_in_backoff()
  end

  # Episodes with a download still occupying them — actively downloading,
  # downloaded-but-awaiting-import, or import-retrying. Excludes imported,
  # client-failed, and terminally-failed imports so those can be re-grabbed.
  # See Mydia.Downloads.Download.occupying/1.
  defp active_episode_download_ids do
    Download.occupying()
    |> where([d], not is_nil(d.episode_id))
    |> select([d], d.episode_id)
    |> distinct(true)
  end

  # Drop episodes covered by an active season-pack download. Mirrors the
  # season-pack arm of Mydia.Downloads.Queue.check_for_active_download/3:
  # matched by (media_item_id, season_number) on downloads whose metadata
  # has season_pack=true.
  defp reject_episodes_in_active_season_packs([]), do: []

  defp reject_episodes_in_active_season_packs(episodes) do
    media_item_ids =
      episodes
      |> Enum.map(& &1.media_item_id)
      |> Enum.uniq()

    covered =
      Download.occupying()
      |> where([d], d.media_item_id in ^media_item_ids)
      |> where(^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
      |> select([d], %{media_item_id: d.media_item_id, metadata: d.metadata})
      |> Repo.all()
      |> Enum.reduce(MapSet.new(), fn
        %{media_item_id: mid, metadata: %{"season_number" => sn}}, acc when is_integer(sn) ->
          MapSet.put(acc, {mid, sn})

        _, acc ->
          acc
      end)

    Enum.reject(episodes, fn e ->
      MapSet.member?(covered, {e.media_item_id, e.season_number})
    end)
  end

  defp load_episodes_for_show(media_item_id) do
    today = Date.utc_today()

    episodes =
      Episode
      |> join(:inner, [e], m in assoc(e, :media_item))
      |> where([e, m], e.media_item_id == ^media_item_id)
      |> where([e, m], e.monitored == true and m.monitored == true)
      |> where([e], e.air_date <= ^today)
      |> join(:left, [e], mf in MediaFile, on: mf.episode_id == e.id and is_nil(mf.trashed_at))
      |> group_by([e], e.id)
      |> having([_e, _m, mf], count(mf.id) == 0)
      |> preload(:media_item)
      |> Repo.all()

    # Filter out special episodes (S00) unless configured to monitor them
    filter_special_episodes(episodes)
  end

  defp load_episodes_for_season(media_item_id, season_number) do
    today = Date.utc_today()

    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e], e.air_date <= ^today)
    |> join(:left, [e], mf in MediaFile, on: mf.episode_id == e.id and is_nil(mf.trashed_at))
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

  defp process_episodes_with_smart_logic(media_item, episodes, search_count, args) do
    max_per_show = get_max_searches_per_show()

    Logger.info("Processing episodes with smart season pack logic",
      media_item_id: media_item.id,
      title: media_item.title,
      total_episodes: length(episodes),
      max_searches_per_show: max_per_show
    )

    # Group episodes by season
    episodes_by_season = Enum.group_by(episodes, & &1.season_number)

    Logger.info("Grouped episodes into #{map_size(episodes_by_season)} seasons")

    # Process each season independently with counter tracking
    {final_count, _seasons_processed} =
      Enum.reduce_while(episodes_by_season, {search_count, 0}, fn {season_number, season_episodes},
                                                                  {show_search_count,
                                                                   seasons_done} ->
        show_searches_used = show_search_count - search_count

        if limit_reached?(show_searches_used, max_per_show) do
          Logger.warning("Per-show search limit reached, skipping remaining seasons",
            media_item_id: media_item.id,
            title: media_item.title,
            searches_for_show: show_searches_used,
            max_searches_per_show: max_per_show,
            seasons_remaining: map_size(episodes_by_season) - seasons_done
          )

          {:halt, {show_search_count, seasons_done}}
        else
          Logger.info("Processing season",
            media_item_id: media_item.id,
            title: media_item.title,
            season_number: season_number,
            missing_episodes: length(season_episodes),
            show_searches_used: show_searches_used
          )

          # Determine if we should prefer season pack
          new_count =
            if should_prefer_season_pack?(season_episodes, media_item, season_number) do
              Logger.info("70% threshold met - preferring season pack",
                media_item_id: media_item.id,
                title: media_item.title,
                season_number: season_number,
                missing_episodes: length(season_episodes)
              )

              # Try season pack first
              search_season(media_item, season_number, season_episodes, show_search_count, args)
            else
              Logger.info("Below 70% threshold - downloading individual episodes",
                media_item_id: media_item.id,
                title: media_item.title,
                season_number: season_number,
                missing_episodes: length(season_episodes)
              )

              # Download individual episodes
              search_individual_episodes(season_episodes, show_search_count, args)
            end

          # Apply rate limiting delay between seasons
          apply_search_delay()

          {:cont, {new_count, seasons_done + 1}}
        end
      end)

    final_count
  end

  @doc false
  # Public for unit testing — internal helper.
  def should_prefer_season_pack?(missing_episodes, media_item, season_number) do
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
    case metadata_episode_count(media_item, season_number) do
      count when is_integer(count) and count > 0 -> count
      _ -> db_episode_count(media_item.id, season_number)
    end
  end

  defp metadata_episode_count(media_item, season_number) do
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

  defp db_episode_count(media_item_id, season_number) do
    case Repo.aggregate(
           from(e in Episode,
             where: e.media_item_id == ^media_item_id and e.season_number == ^season_number
           ),
           :count
         ) do
      0 -> nil
      n -> n
    end
  end

  ## Private Functions - Season Search Logic

  defp search_season(media_item, season_number, episodes, search_count, args) do
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
      query: query,
      search_count: search_count
    )

    # Increment counter for the season pack search
    new_count = search_count + 1

    case Indexers.search_all(query, min_seeders: get_min_seeders()) do
      {:ok, %{results: []}} ->
        Logger.warning("No season pack results found, falling back to individual episodes",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number
        )

        # Record backoff for season pack no results
        record_season_backoff(media_item, season_number, "no_results")

        # Log no results event for season pack search
        Events.search_no_results(
          media_item,
          %{
            "query" => query,
            "indexers_searched" => count_enabled_indexers(),
            "season_number" => season_number,
            "search_type" => "season_pack"
          }
        )

        # Fall back to searching individual episodes
        search_individual_episodes(episodes, new_count, args)

      {:ok, %{results: results}} ->
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

          # Log filtered out event with detailed results
          Events.search_filtered_out(
            media_item,
            %{
              "query" => query,
              "results_count" => length(results),
              "season_number" => season_number,
              "search_type" => "season_pack",
              "filter_stats" => build_season_pack_filter_stats(results, season_number)
            }
          )

          search_individual_episodes(episodes, new_count, args)
        else
          result =
            process_season_pack_results(
              media_item,
              season_number,
              episodes,
              season_pack_results,
              args,
              query
            )

          # If season pack processing failed, fall back to individual episodes
          # But if it's a duplicate (already downloading), skip entirely
          case result do
            :ok ->
              new_count

            {:error, :duplicate_download} ->
              Logger.info(
                "Season pack already downloading, skipping individual episode search",
                media_item_id: media_item.id,
                title: media_item.title,
                season_number: season_number
              )

              new_count

            :no_results ->
              search_individual_episodes(episodes, new_count, args)

            {:error, _reason} ->
              search_individual_episodes(episodes, new_count, args)
          end
        end
    end
  end

  # Checks if a release title looks like a season pack (has season marker but no episode marker)
  defp season_pack?(result_title, season_number) do
    season_marker = "S#{String.pad_leading("#{season_number}", 2, "0")}"
    title_upper = String.upcase(result_title)

    String.contains?(title_upper, season_marker) and
      not Regex.match?(~r/E\d{2}/i, title_upper)
  end

  defp filter_season_packs(results, season_number) do
    Enum.filter(results, &season_pack?(&1.title, season_number))
  end

  # Build filter stats for season pack filtering (results rejected because they're individual episodes)
  defp build_season_pack_filter_stats(results, season_number) do
    season_marker = "S#{String.pad_leading("#{season_number}", 2, "0")}"
    episode_marker_regex = ~r/E\d{2}/i

    # Categorize each result
    results_details =
      results
      |> Enum.take(10)
      |> Enum.map(fn result ->
        title_upper = String.upcase(result.title)
        has_season = String.contains?(title_upper, season_marker)
        has_episode = Regex.match?(episode_marker_regex, title_upper)

        size_mb =
          if result.size, do: Float.round(result.size / (1024 * 1024), 1), else: 0.0

        resolution = if result.quality, do: result.quality.resolution, else: nil

        rejection_reason =
          cond do
            has_episode -> "individual_episode"
            not has_season -> "missing_season_marker"
            true -> nil
          end

        %{
          "title" => result.title,
          "score" => 0.0,
          "seeders" => result.seeders,
          "size_mb" => size_mb,
          "resolution" => resolution,
          "status" => if(rejection_reason, do: "rejected", else: "accepted"),
          "rejection_reason" => rejection_reason
        }
      end)

    # Count rejections by type
    individual_episodes =
      Enum.count(results, fn result ->
        Regex.match?(episode_marker_regex, String.upcase(result.title))
      end)

    missing_season =
      Enum.count(results, fn result ->
        not String.contains?(String.upcase(result.title), season_marker)
      end)

    %{
      "total_results" => length(results),
      "rejection_counts" => %{
        "individual_episode" => individual_episodes,
        "missing_season_marker" => missing_season
      },
      "results" => results_details
    }
  end

  defp process_season_pack_results(media_item, season_number, episodes, results, args, query) do
    # Filter blacklisted releases out before ranking (#123). Too-fresh NZB
    # filtering (#121) already happened upstream in `Indexers.search_all/2`
    # — see the call site in MovieSearch for the rationale.
    results = reject_blacklisted(results, media_item: media_item, season_number: season_number)

    # Build ranking options from the first episode (they all share the same show)
    ranking_opts = build_ranking_options_for_season(media_item, season_number, episodes, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning(
          "No suitable season pack after ranking",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          total_results: length(results)
        )

        # Record backoff for season pack filtered out
        record_season_backoff(media_item, season_number, "all_filtered")

        # Log filtered out event
        Events.search_filtered_out(
          media_item,
          %{
            "query" => query,
            "results_count" => length(results),
            "season_number" => season_number,
            "search_type" => "season_pack",
            "filter_stats" => build_filter_stats(results, ranking_opts)
          }
        )

        # Return :no_results to signal fallback needed
        :no_results

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

        # Log search completed event - search found and selected a result
        Events.search_completed(
          media_item,
          %{
            "query" => query,
            "results_count" => length(results),
            "selected_release" => best_result.title,
            "score" => score,
            "breakdown" => stringify_keys(breakdown),
            "season_number" => season_number,
            "search_type" => "season_pack",
            "episodes_included" => length(episodes),
            "all_results" => build_filter_stats(results, ranking_opts)
          }
        )

        case initiate_season_pack_download(media_item, season_number, episodes, best_result) do
          :ok ->
            # Reset season backoff on successful download initiation
            reset_season_backoff(media_item, season_number)
            :ok

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(
              media_item,
              reason,
              %{
                "query" => query,
                "results_count" => length(results),
                "selected_release" => best_result.title,
                "score" => score,
                "season_number" => season_number,
                "search_type" => "season_pack"
              }
            )

            {:error, reason}
        end
    end
  end

  defp search_individual_episodes(episodes, search_count, args) do
    max_per_season = get_max_searches_per_season()

    # Prioritize newer episodes (sort by air_date descending)
    prioritized = prioritize_episodes(episodes)

    Logger.info("Searching for individual episodes",
      total_episodes: length(episodes),
      max_searches_per_season: max_per_season,
      current_search_count: search_count
    )

    {final_count, successful, failed, skipped} =
      Enum.reduce_while(
        prioritized,
        {search_count, 0, 0, 0},
        fn episode, {current_count, ok_count, err_count, skip_count} ->
          season_searches = current_count - search_count

          if limit_reached?(season_searches, max_per_season) do
            remaining = length(prioritized) - (ok_count + err_count + skip_count)

            Logger.warning("Per-season search limit reached, skipping remaining episodes",
              season_number: episode.season_number,
              searches_this_season: season_searches,
              max_searches_per_season: max_per_season,
              episodes_skipped: remaining
            )

            {:halt, {current_count, ok_count, err_count, skip_count + remaining}}
          else
            result = search_episode(episode, args)

            # Apply rate limiting delay between searches
            apply_search_delay()

            new_counts =
              case result do
                :ok -> {current_count + 1, ok_count + 1, err_count, skip_count}
                {:error, _} -> {current_count + 1, ok_count, err_count + 1, skip_count}
              end

            {:cont, new_counts}
          end
        end
      )

    Logger.info("Individual episode search completed",
      total: length(episodes),
      successful: successful,
      failed: failed,
      skipped: skipped,
      searches_performed: final_count - search_count
    )

    final_count
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

    case Indexers.search_all(query, min_seeders: get_min_seeders()) do
      {:ok, %{results: []}} ->
        Logger.warning("No results found for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          query: query
        )

        # Record backoff for no results
        record_episode_backoff(episode, "no_results")

        # Log search event for no results
        Events.search_no_results(
          episode.media_item,
          %{"query" => query, "indexers_searched" => count_enabled_indexers()},
          episode: episode
        )

        :ok

      {:ok, %{results: results}} ->
        Logger.info("Found #{length(results)} results for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number
        )

        process_episode_results(episode, results, args, query)
    end
  end

  defp process_episode_results(episode, results, args, query) do
    # Season packs are no longer hard-rejected here. Episode/season identity is
    # judged inside ReleaseRanker via the identity penalty (R6): for an episode
    # search a season pack matches the season but lacks the episode, so it is
    # penalized and kept as a low-tier fallback rather than removed. This makes
    # the formerly-unreachable "all season packs" backoff branch obsolete — an
    # episode search whose results are all season packs now ranks and can select
    # the penalized pack instead of recording a backoff and grabbing nothing.
    #
    # Filter blacklisted releases out before ranking (#123). The "filter,
    # don't rank" convention keeps this distinct from `ReleaseRanker`.
    # Too-fresh NZB filtering (#121) already happened upstream in
    # `Indexers.search_all/2`.
    episode_results = reject_blacklisted(results, episode: episode)

    process_ranked_episode_results(episode, episode_results, args, query)
  end

  # Drops results matching an active `(indexer, guid)` row in the
  # release_blacklist table. Logs each rejection at :info with the
  # identifying pair so operators can debug why a result vanished.
  defp reject_blacklisted(results, ctx) do
    episode_id = Keyword.get(ctx, :episode) && Keyword.get(ctx, :episode).id
    media_item_id = Keyword.get(ctx, :media_item) && Keyword.get(ctx, :media_item).id
    Blacklists.reject_blacklisted(results, episode_id: episode_id, media_item_id: media_item_id)
  end

  defp process_ranked_episode_results(episode, results, args, query) do
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

        # Record backoff for all results filtered out
        record_episode_backoff(episode, "all_filtered")

        # Log search event for all results filtered out
        Events.search_filtered_out(
          episode.media_item,
          %{
            "query" => query,
            "results_count" => length(results),
            "filter_stats" => build_filter_stats(results, ranking_opts)
          },
          episode: episode
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

        # Log search completed event - search found and selected a result
        Events.search_completed(
          episode.media_item,
          %{
            "query" => query,
            "results_count" => length(results),
            "selected_release" => best_result.title,
            "score" => score,
            "breakdown" => stringify_keys(breakdown),
            "all_results" => build_filter_stats(results, ranking_opts)
          },
          episode: episode
        )

        case initiate_episode_download(episode, best_result) do
          :ok ->
            # Reset backoff on successful download initiation
            reset_episode_backoff(episode)
            :ok

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(
              episode.media_item,
              reason,
              %{
                "query" => query,
                "results_count" => length(results),
                "selected_release" => best_result.title,
                "score" => score
              },
              episode: episode
            )

            {:error, reason}
        end
    end
  end

  ## Private Functions - Quality & Ranking

  defp build_ranking_options(episode, %Args{} = args) do
    # Delegate to the shared RankingOptions builder. An episode search supplies
    # the expected season AND episode so the ranker's identity penalty can rank
    # the requested episode above wrong episodes and season packs (which match
    # the season but lack the episode).
    RankingOptions.build(%{
      quality_profile: QualityProfileResolver.resolve(episode.media_item),
      media_type: :episode,
      min_seeders: args.min_seeders || get_min_seeders(),
      size_range: args.size_range,
      search_query: build_episode_query(episode),
      expected_title: episode.media_item.title,
      expected_season: episode.season_number,
      expected_episode: episode.episode_number,
      blocked_tags: merged_blocked_tags(args.blocked_tags),
      preferred_tags: args.preferred_tags
    })
  end

  defp build_ranking_options_for_season(media_item, season_number, _episodes, %Args{} = args) do
    # Delegate to the shared RankingOptions builder. A season-pack search
    # supplies only the expected season (no episode), so the identity penalty
    # matches on season alone — a season pack for the requested season matches,
    # a wrong-season pack is penalized.
    RankingOptions.build(%{
      quality_profile: QualityProfileResolver.resolve(media_item),
      media_type: :episode,
      min_seeders: args.min_seeders || get_min_seeders(),
      size_range: args.size_range,
      search_query: build_season_query(media_item, season_number),
      expected_title: media_item.title,
      expected_season: season_number,
      blocked_tags: merged_blocked_tags(args.blocked_tags),
      preferred_tags: args.preferred_tags
    })
  end

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

    # Build season pack metadata struct so dedup pattern matches in
    # Mydia.Downloads.Queue and persistence in DownloadMetadata work correctly.
    metadata =
      SearchResultMetadata.season_pack(
        season_number,
        length(episodes),
        Enum.map(episodes, & &1.id)
      )

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
    active_files_query = from(mf in MediaFile, where: is_nil(mf.trashed_at))
    episode = Repo.preload(episode, [media_files: active_files_query], force: true)
    episode.media_files != []
  end

  defp future_episode?(%Episode{air_date: nil}), do: false

  defp future_episode?(%Episode{air_date: air_date}) do
    Date.compare(air_date, Date.utc_today()) == :gt
  end

  ## Private Functions - Search Limit Configuration

  defp get_max_searches_per_run do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:max_searches_per_run, :infinity)
  end

  defp get_max_searches_per_show do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:max_searches_per_show, :infinity)
  end

  defp get_max_searches_per_season do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:max_searches_per_season, :infinity)
  end

  defp monitor_special_episodes? do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:monitor_special_episodes, false)
  end

  defp get_search_delay_ms do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:search_delay_ms, 0)
  end

  defp apply_search_delay do
    delay = get_search_delay_ms()

    if delay > 0 do
      Process.sleep(delay)
    end
  end

  defp limit_reached?(_current, :infinity), do: false
  defp limit_reached?(current, max) when current >= max, do: true
  defp limit_reached?(_current, _max), do: false

  defp prioritize_episodes(episodes) do
    # Sort by air_date descending (newest first) to prioritize recent content
    Enum.sort_by(episodes, & &1.air_date, {:desc, Date})
  end

  defp filter_special_episodes(episodes) do
    if monitor_special_episodes?() do
      episodes
    else
      {regular, specials} = Enum.split_with(episodes, &(&1.season_number != 0))

      if specials != [] do
        Logger.info(
          "Skipping #{length(specials)} special episodes (S00) - monitor_special_episodes is disabled"
        )
      end

      regular
    end
  end

  defp filter_episodes_in_backoff(episodes) do
    {eligible, in_backoff} =
      Enum.split_with(episodes, fn episode ->
        Search.eligible?("episode", episode.id)
      end)

    if in_backoff != [] do
      Logger.info("Skipping #{length(in_backoff)} episodes in backoff")
    end

    eligible
  end

  ## Private Functions - Backoff Helpers

  defp record_episode_backoff(%Episode{} = episode, reason) do
    case Search.record_failure("episode", episode.id, reason) do
      {:ok, backoff} ->
        Logger.info("Applied search backoff for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          failure_count: backoff.failure_count,
          next_eligible_at: backoff.next_eligible_at,
          reason: reason
        )

        # Emit backoff event
        Events.search_backoff_applied(
          episode.media_item,
          reason,
          Search.get_backoff_info("episode", episode.id),
          episode: episode
        )

      {:error, changeset} ->
        Logger.error("Failed to record search backoff for episode",
          episode_id: episode.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp reset_episode_backoff(%Episode{} = episode) do
    case Search.get_backoff("episode", episode.id) do
      nil ->
        :ok

      backoff ->
        previous_count = backoff.failure_count
        Search.reset_backoff("episode", episode.id)

        Logger.info("Reset search backoff for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          previous_failure_count: previous_count
        )

        # Emit backoff reset event
        Events.search_backoff_reset(
          episode.media_item,
          previous_count,
          episode: episode
        )
    end
  end

  defp record_season_backoff(%MediaItem{} = media_item, season_number, reason) do
    case Search.record_failure("season", media_item.id, reason, season_number: season_number) do
      {:ok, backoff} ->
        Logger.info("Applied search backoff for season",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          failure_count: backoff.failure_count,
          next_eligible_at: backoff.next_eligible_at,
          reason: reason
        )

        # Emit backoff event
        Events.search_backoff_applied(
          media_item,
          reason,
          Search.get_backoff_info("season", media_item.id, season_number: season_number),
          season_number: season_number
        )

      {:error, changeset} ->
        Logger.error("Failed to record search backoff for season",
          media_item_id: media_item.id,
          season_number: season_number,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp reset_season_backoff(%MediaItem{} = media_item, season_number) do
    case Search.get_backoff("season", media_item.id, season_number: season_number) do
      nil ->
        :ok

      backoff ->
        previous_count = backoff.failure_count
        Search.reset_backoff("season", media_item.id, season_number: season_number)

        Logger.info("Reset search backoff for season",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number,
          previous_failure_count: previous_count
        )

        # Emit backoff reset event
        Events.search_backoff_reset(
          media_item,
          previous_count,
          season_number: season_number
        )
    end
  end

  ## Private Functions - Stats Tracking

  defp broadcast_search_completed(media_item_id, stats) do
    PubSub.broadcast(
      Mydia.PubSub,
      "downloads",
      {:search_completed, media_item_id, stats}
    )
  end

  defp count_enabled_indexers do
    # Count enabled indexers from Settings
    indexers = Mydia.Settings.list_indexer_configs()
    enabled_count = Enum.count(indexers, & &1.enabled)

    # Also count Cardigann indexers if feature is enabled
    cardigann_count =
      if Application.get_env(:mydia, :features, [])[:cardigann_indexers] do
        Mydia.Indexers.list_cardigann_definitions()
        |> Enum.count(& &1.enabled)
      else
        0
      end

    enabled_count + cardigann_count
  end

  defp process_episodes_with_smart_logic_and_stats(
         media_item,
         episodes,
         search_count,
         args,
         stats
       ) do
    max_per_show = get_max_searches_per_show()

    Logger.info("Processing episodes with smart season pack logic (with stats)",
      media_item_id: media_item.id,
      title: media_item.title,
      total_episodes: length(episodes),
      max_searches_per_show: max_per_show
    )

    # Group episodes by season
    episodes_by_season = Enum.group_by(episodes, & &1.season_number)

    Logger.info("Grouped episodes into #{map_size(episodes_by_season)} seasons")

    # Process each season independently with counter and stats tracking
    {final_count, _seasons_processed, final_stats} =
      Enum.reduce_while(
        episodes_by_season,
        {search_count, 0, stats},
        fn {season_number, season_episodes}, {show_search_count, seasons_done, current_stats} ->
          show_searches_used = show_search_count - search_count

          if limit_reached?(show_searches_used, max_per_show) do
            Logger.warning("Per-show search limit reached, skipping remaining seasons",
              media_item_id: media_item.id,
              title: media_item.title,
              searches_for_show: show_searches_used,
              max_searches_per_show: max_per_show,
              seasons_remaining: map_size(episodes_by_season) - seasons_done
            )

            {:halt, {show_search_count, seasons_done, current_stats}}
          else
            Logger.info("Processing season",
              media_item_id: media_item.id,
              title: media_item.title,
              season_number: season_number,
              missing_episodes: length(season_episodes),
              show_searches_used: show_searches_used
            )

            # Determine if we should prefer season pack
            {new_count, season_stats} =
              if should_prefer_season_pack?(season_episodes, media_item, season_number) do
                Logger.info("70% threshold met - preferring season pack",
                  media_item_id: media_item.id,
                  title: media_item.title,
                  season_number: season_number,
                  missing_episodes: length(season_episodes)
                )

                # Try season pack first
                search_season_with_stats(
                  media_item,
                  season_number,
                  season_episodes,
                  show_search_count,
                  args
                )
              else
                Logger.info("Below 70% threshold - downloading individual episodes",
                  media_item_id: media_item.id,
                  title: media_item.title,
                  season_number: season_number,
                  missing_episodes: length(season_episodes)
                )

                # Download individual episodes
                search_individual_episodes_with_stats(season_episodes, show_search_count, args)
              end

            # Merge stats
            updated_stats = %{
              results_found: current_stats.results_found + season_stats.results_found,
              downloads_initiated:
                current_stats.downloads_initiated + season_stats.downloads_initiated
            }

            # Apply rate limiting delay between seasons
            apply_search_delay()

            {:cont, {new_count, seasons_done + 1, updated_stats}}
          end
        end
      )

    {final_count, final_stats}
  end

  defp search_season_with_stats(media_item, season_number, episodes, search_count, args) do
    query = build_season_query(media_item, season_number)

    Logger.info("Searching for season pack",
      media_item_id: media_item.id,
      title: media_item.title,
      season_number: season_number,
      query: query,
      search_count: search_count
    )

    # Increment counter for the season pack search
    new_count = search_count + 1

    case Indexers.search_all(query, min_seeders: get_min_seeders()) do
      {:ok, %{results: []}} ->
        Logger.warning("No season pack results found, falling back to individual episodes",
          media_item_id: media_item.id,
          title: media_item.title,
          season_number: season_number
        )

        # Log no results event for season pack search
        Events.search_no_results(
          media_item,
          %{
            "query" => query,
            "indexers_searched" => count_enabled_indexers(),
            "season_number" => season_number,
            "search_type" => "season_pack"
          }
        )

        # Fall back to searching individual episodes
        search_individual_episodes_with_stats(episodes, new_count, args)

      {:ok, %{results: results}} ->
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

          # Log filtered out event with detailed results
          Events.search_filtered_out(
            media_item,
            %{
              "query" => query,
              "results_count" => length(results),
              "season_number" => season_number,
              "search_type" => "season_pack",
              "filter_stats" => build_season_pack_filter_stats(results, season_number)
            }
          )

          {count, ep_stats} = search_individual_episodes_with_stats(episodes, new_count, args)
          # Add the season pack results to the stats
          {count, %{ep_stats | results_found: ep_stats.results_found + length(results)}}
        else
          result =
            process_season_pack_results(
              media_item,
              season_number,
              episodes,
              season_pack_results,
              args,
              query
            )

          # If season pack processing failed, fall back to individual episodes
          # But if it's a duplicate (already downloading), skip entirely
          case result do
            :ok ->
              {new_count, %{results_found: length(results), downloads_initiated: 1}}

            {:error, :duplicate_download} ->
              Logger.info(
                "Season pack already downloading, skipping individual episode search",
                media_item_id: media_item.id,
                title: media_item.title,
                season_number: season_number
              )

              {new_count, %{results_found: length(results), downloads_initiated: 0}}

            :no_results ->
              {count, ep_stats} = search_individual_episodes_with_stats(episodes, new_count, args)
              {count, %{ep_stats | results_found: ep_stats.results_found + length(results)}}

            {:error, _reason} ->
              {count, ep_stats} = search_individual_episodes_with_stats(episodes, new_count, args)
              {count, %{ep_stats | results_found: ep_stats.results_found + length(results)}}
          end
        end
    end
  end

  defp search_individual_episodes_with_stats(episodes, search_count, args) do
    max_per_season = get_max_searches_per_season()

    # Prioritize newer episodes (sort by air_date descending)
    prioritized = prioritize_episodes(episodes)

    Logger.info("Searching for individual episodes (with stats)",
      total_episodes: length(episodes),
      max_searches_per_season: max_per_season,
      current_search_count: search_count
    )

    {final_count, successful, failed, skipped, total_results} =
      Enum.reduce_while(
        prioritized,
        {search_count, 0, 0, 0, 0},
        fn episode, {current_count, ok_count, err_count, skip_count, results_count} ->
          season_searches = current_count - search_count

          if limit_reached?(season_searches, max_per_season) do
            remaining = length(prioritized) - (ok_count + err_count + skip_count)

            Logger.warning("Per-season search limit reached, skipping remaining episodes",
              season_number: episode.season_number,
              searches_this_season: season_searches,
              max_searches_per_season: max_per_season,
              episodes_skipped: remaining
            )

            {:halt, {current_count, ok_count, err_count, skip_count + remaining, results_count}}
          else
            {result, ep_results} = search_episode_with_stats(episode, args)

            # Apply rate limiting delay between searches
            apply_search_delay()

            new_counts =
              case result do
                :ok ->
                  {current_count + 1, ok_count + 1, err_count, skip_count,
                   results_count + ep_results}

                {:error, _} ->
                  {current_count + 1, ok_count, err_count + 1, skip_count,
                   results_count + ep_results}
              end

            {:cont, new_counts}
          end
        end
      )

    Logger.info("Individual episode search completed (with stats)",
      total: length(episodes),
      successful: successful,
      failed: failed,
      skipped: skipped,
      searches_performed: final_count - search_count
    )

    {final_count, %{results_found: total_results, downloads_initiated: successful}}
  end

  defp search_episode_with_stats(%Episode{} = episode, args) do
    # Skip if episode already has files
    if has_media_files?(episode) do
      Logger.debug("Episode already has files, skipping",
        episode_id: episode.id,
        season: episode.season_number,
        episode: episode.episode_number
      )

      {:ok, 0}
    else
      # Skip if episode hasn't aired yet
      if future_episode?(episode) do
        Logger.debug("Episode has future air date, skipping",
          episode_id: episode.id,
          season: episode.season_number,
          episode: episode.episode_number,
          air_date: episode.air_date
        )

        {:ok, 0}
      else
        perform_episode_search_with_stats(episode, args)
      end
    end
  end

  defp perform_episode_search_with_stats(%Episode{} = episode, args) do
    query = build_episode_query(episode)

    Logger.info("Searching for episode (with stats)",
      episode_id: episode.id,
      show: episode.media_item.title,
      season: episode.season_number,
      episode: episode.episode_number,
      query: query
    )

    case Indexers.search_all(query, min_seeders: get_min_seeders()) do
      {:ok, %{results: []}} ->
        Logger.warning("No results found for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number,
          query: query
        )

        # Log search event for no results
        Events.search_no_results(
          episode.media_item,
          %{"query" => query, "indexers_searched" => count_enabled_indexers()},
          episode: episode
        )

        {:ok, 0}

      {:ok, %{results: results}} ->
        Logger.info("Found #{length(results)} results for episode",
          episode_id: episode.id,
          show: episode.media_item.title,
          season: episode.season_number,
          episode: episode.episode_number
        )

        case process_episode_results(episode, results, args, query) do
          :ok -> {:ok, length(results)}
          {:error, _} = err -> {err, length(results)}
        end
    end
  end

  ## Private Functions - Event Helpers

  # Build a map of filter statistics for the Activity view. Delegates to the
  # shared ReleaseRanker.build_filter_stats/2 so movie and TV render identically,
  # including the penalized-but-kept state.
  defp build_filter_stats(results, ranking_opts) do
    ReleaseRanker.build_filter_stats(results, ranking_opts)
  end

  # Convert a map with atom keys to string keys for JSON serialization
  defp stringify_keys(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
