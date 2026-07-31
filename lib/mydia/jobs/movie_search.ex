defmodule Mydia.Jobs.MovieSearch do
  @moduledoc """
  Background job for searching and downloading movie releases.

  This job searches indexers for movie releases and initiates downloads
  for the best matches. Supports both background execution for all monitored
  movies and UI-triggered searches for specific movies.

  ## Execution Modes

  - `"all_monitored"` - Search all monitored movies without files (scheduled)
  - `"specific"` - Search a single movie by ID (UI-triggered)

  ## Examples

      # Queue a search for all monitored movies
      %{mode: "all_monitored"}
      |> MovieSearch.new()
      |> Oban.insert()

      # Queue a search for a specific movie
      %{mode: "specific", media_item_id: 123}
      |> MovieSearch.new()
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
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Phoenix.PubSub

  defmodule Args do
    @moduledoc false
    defstruct [
      :mode,
      :media_item_id,
      :min_seeders,
      :size_range,
      :blocked_tags,
      :preferred_tags
    ]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            media_item_id: String.t() | nil,
            min_seeders: integer() | nil,
            size_range: term() | nil,
            blocked_tags: [String.t()] | nil,
            preferred_tags: [String.t()] | nil
          }

    def parse(%{"mode" => "all_monitored"} = raw) do
      %__MODULE__{
        mode: "all_monitored",
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
    end

    def parse(%{"mode" => "specific", "media_item_id" => media_item_id} = raw) do
      %__MODULE__{
        mode: "specific",
        media_item_id: media_item_id,
        min_seeders: Map.get(raw, "min_seeders"),
        size_range: Map.get(raw, "size_range"),
        blocked_tags: Map.get(raw, "blocked_tags"),
        preferred_tags: Map.get(raw, "preferred_tags")
      }
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
  def perform(%Oban.Job{args: %{"mode" => "all_monitored"} = raw_args}) do
    args = Args.parse(raw_args)
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting automatic search for all monitored movies")

    movies = load_monitored_movies_without_files()
    total_count = length(movies)

    Logger.info("Found #{total_count} monitored movies without files")

    if total_count == 0 do
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("No movies to search", duration_ms: duration)

      :ok
    else
      results =
        Enum.map(movies, fn movie ->
          result = search_movie(movie, args)
          apply_search_delay()
          result
        end)

      successful = Enum.count(results, &(&1 == :ok))
      failed = Enum.count(results, &match?({:error, _}, &1))
      no_results = Enum.count(results, &(&1 == :no_results))
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Automatic movie search completed",
        duration_ms: duration,
        total: total_count,
        successful: successful,
        failed: failed,
        no_results: no_results
      )

      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "specific"} = raw_args}) do
    args = Args.parse(raw_args)
    media_item_id = args.media_item_id
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting search for specific movie", media_item_id: media_item_id)

    result =
      try do
        media_item = Media.get_media_item!(media_item_id)

        case media_item do
          %MediaItem{type: "movie"} = movie ->
            search_movie_with_stats(movie, args)

          %MediaItem{type: type} ->
            Logger.error("Invalid media type for movie search",
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
        Logger.info("Movie search completed",
          duration_ms: duration,
          media_item_id: media_item_id,
          stats: stats
        )

        # Broadcast search completion for UI feedback
        broadcast_search_completed(media_item_id, stats)

        :ok

      {:no_results, stats} ->
        Logger.info("Movie search completed with no results",
          duration_ms: duration,
          media_item_id: media_item_id,
          stats: stats
        )

        # Broadcast search completion for UI feedback
        broadcast_search_completed(media_item_id, stats)

        :ok

      {:error, reason} ->
        Logger.error("Movie search failed",
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

  ## Private Functions

  defp broadcast_search_completed(media_item_id, stats) do
    PubSub.broadcast(
      Mydia.PubSub,
      "downloads",
      {:search_completed, media_item_id, stats}
    )
  end

  defp search_movie_with_stats(%MediaItem{} = movie, args) do
    query = build_search_query(movie)
    indexers_count = count_enabled_indexers()

    Logger.info("Searching for movie",
      media_item_id: movie.id,
      title: movie.title,
      year: movie.year,
      query: query,
      indexers_count: indexers_count
    )

    min_seeders = get_min_seeders()

    case Indexers.search_all(query, min_seeders: min_seeders) do
      {:ok, %{results: [], indexer_errors: indexer_errors}} ->
        if indexer_errors != [] do
          Logger.warning("Movie search failed due to indexer errors",
            media_item_id: movie.id,
            title: movie.title,
            query: query,
            errors: inspect(indexer_errors)
          )
        end

        Logger.warning("No results found for movie",
          media_item_id: movie.id,
          title: movie.title,
          query: query
        )

        # Log search event for no results
        Events.search_no_results(movie, %{
          "query" => query,
          "indexers_searched" => indexers_count
        })

        {:no_results,
         %{
           indexers_searched: indexers_count,
           results_found: 0,
           downloads_initiated: 0
         }}

      {:ok, %{results: results}} ->
        Logger.info("Found #{length(results)} results for movie",
          media_item_id: movie.id,
          title: movie.title
        )

        {status, downloads_initiated} =
          process_search_results_with_count(movie, results, args, query)

        stats = %{
          indexers_searched: indexers_count,
          results_found: length(results),
          downloads_initiated: downloads_initiated
        }

        case status do
          :ok -> {:ok, stats}
          :no_results -> {:no_results, stats}
        end
    end
  end

  defp process_search_results_with_count(movie, results, args, query) do
    # Filter blacklisted releases out before ranking (#123).
    # NB: too-fresh NZB filtering (#121) happens upstream inside
    # `Indexers.search_all/2` where the originating indexer config is in
    # scope — relay-style indexers (Prowlarr, Jackett) tag results with
    # their *upstream* indexer label, which would not match the configured
    # Mydia indexer name in a post-merge lookup.
    results = reject_blacklisted(results, movie: movie)
    ranking_opts = build_ranking_options(movie, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning("No suitable results after ranking for movie",
          media_item_id: movie.id,
          title: movie.title,
          total_results: length(results)
        )

        # Log search event for all results filtered out
        Events.search_filtered_out(movie, %{
          "query" => query,
          "results_count" => length(results),
          "filter_stats" => build_filter_stats(results, ranking_opts)
        })

        {:no_results, 0}

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best result for movie",
          media_item_id: movie.id,
          title: movie.title,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown
        )

        # Log search completed event - search found and selected a result
        Events.search_completed(movie, %{
          "query" => query,
          "results_count" => length(results),
          "selected_release" => best_result.title,
          "score" => score,
          "breakdown" => stringify_keys(breakdown)
        })

        case initiate_download(movie, best_result) do
          :ok ->
            {:ok, 1}

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(movie, reason, %{
              "query" => query,
              "results_count" => length(results),
              "selected_release" => best_result.title,
              "score" => score
            })

            {:no_results, 0}
        end
    end
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

  @doc false
  # Public for direct testing of the search-selection filter.
  def load_monitored_movies_without_files do
    movies =
      MediaItem
      |> where([m], m.type == "movie")
      |> where([m], m.monitored == true)
      |> where([m], m.id not in subquery(active_download_media_item_ids()))
      |> join(:left, [m], mf in MediaFile, on: mf.media_item_id == m.id and is_nil(mf.trashed_at))
      |> group_by([m], m.id)
      |> having([m, mf], count(mf.id) == 0)
      |> Repo.all()

    filter_movies_in_backoff(movies)
  end

  # media_item_ids with an in-flight download (still in client, not failed).
  # Matches Mydia.Downloads.Queue.check_for_active_download/3 so we skip
  # indexer calls for items the queue would reject anyway.
  defp active_download_media_item_ids do
    from(d in Download,
      where: is_nil(d.completed_at) and is_nil(d.error_message),
      where: not is_nil(d.media_item_id),
      select: d.media_item_id,
      distinct: true
    )
  end

  defp filter_movies_in_backoff(movies) do
    {eligible, in_backoff} =
      Enum.split_with(movies, fn movie ->
        Search.eligible?("movie", movie.id)
      end)

    if in_backoff != [] do
      Logger.info("Skipping #{length(in_backoff)} movies in backoff")
    end

    eligible
  end

  defp search_movie(%MediaItem{} = movie, args) do
    query = build_search_query(movie)

    Logger.info("Searching for movie",
      media_item_id: movie.id,
      title: movie.title,
      year: movie.year,
      query: query
    )

    min_seeders = get_min_seeders()

    case Indexers.search_all(query, min_seeders: min_seeders) do
      {:ok, %{results: [], indexer_errors: indexer_errors}} ->
        if indexer_errors != [] do
          Logger.warning("Movie search failed due to indexer errors",
            media_item_id: movie.id,
            title: movie.title,
            query: query,
            errors: inspect(indexer_errors)
          )
        end

        Logger.warning("No results found for movie",
          media_item_id: movie.id,
          title: movie.title,
          query: query
        )

        # Record backoff for no results
        record_movie_backoff(movie, "no_results")

        # Log search event for no results
        Events.search_no_results(movie, %{
          "query" => query,
          "indexers_searched" => count_enabled_indexers()
        })

        :no_results

      {:ok, %{results: results}} ->
        Logger.info("Found #{length(results)} results for movie",
          media_item_id: movie.id,
          title: movie.title
        )

        process_search_results(movie, results, args, query)
    end
  end

  defp build_search_query(%MediaItem{title: title, year: nil}) do
    title
  end

  defp build_search_query(%MediaItem{title: title, year: year}) do
    "#{title} #{year}"
  end

  defp process_search_results(movie, results, args, query) do
    # Filter blacklisted releases out before ranking (#123).
    # NB: too-fresh NZB filtering (#121) happens upstream inside
    # `Indexers.search_all/2` where the originating indexer config is in
    # scope — relay-style indexers (Prowlarr, Jackett) tag results with
    # their *upstream* indexer label, which would not match the configured
    # Mydia indexer name in a post-merge lookup.
    results = reject_blacklisted(results, movie: movie)
    ranking_opts = build_ranking_options(movie, args)

    case ReleaseRanker.select_best_result(results, ranking_opts) do
      nil ->
        Logger.warning("No suitable results after ranking for movie",
          media_item_id: movie.id,
          title: movie.title,
          total_results: length(results)
        )

        # Record backoff for all results filtered out
        record_movie_backoff(movie, "all_filtered")

        # Log search event for all results filtered out
        Events.search_filtered_out(movie, %{
          "query" => query,
          "results_count" => length(results),
          "filter_stats" => build_filter_stats(results, ranking_opts)
        })

        :no_results

      %{result: best_result, score: score, breakdown: breakdown} ->
        Logger.info("Selected best result for movie",
          media_item_id: movie.id,
          title: movie.title,
          result_title: best_result.title,
          score: score,
          breakdown: breakdown
        )

        # Log search completed event - search found and selected a result
        Events.search_completed(movie, %{
          "query" => query,
          "results_count" => length(results),
          "selected_release" => best_result.title,
          "score" => score,
          "breakdown" => stringify_keys(breakdown)
        })

        case initiate_download(movie, best_result) do
          :ok ->
            # Reset backoff on successful download initiation
            reset_movie_backoff(movie)
            :ok

          {:error, reason} ->
            # Also log download failure event
            Events.download_initiation_failed(movie, reason, %{
              "query" => query,
              "results_count" => length(results),
              "selected_release" => best_result.title,
              "score" => score
            })

            :no_results
        end
    end
  end

  defp build_ranking_options(movie, %Args{} = args) do
    # Delegate to the shared RankingOptions builder so movie and TV search use
    # one option-building path. A movie expects no season/episode identity, so
    # no expected_season/expected_episode are supplied (a TV-pattern release is
    # softly penalized as an identity mismatch inside the ranker).
    RankingOptions.build(%{
      quality_profile: QualityProfileResolver.resolve(movie),
      media_type: :movie,
      min_seeders: args.min_seeders || get_min_seeders(),
      size_range: args.size_range,
      search_query: build_search_query(movie),
      expected_title: movie.title,
      blocked_tags: merged_blocked_tags(args.blocked_tags),
      preferred_tags: args.preferred_tags
    })
  end

  defp initiate_download(movie, result) do
    case Downloads.initiate_download(result, media_item_id: movie.id) do
      {:ok, download} ->
        Logger.info("Successfully initiated download for movie",
          media_item_id: movie.id,
          title: movie.title,
          download_id: download.id,
          result_title: result.title
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to initiate download for movie",
          media_item_id: movie.id,
          title: movie.title,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions - Search Delay

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

  ## Private Functions - Backoff Helpers

  defp record_movie_backoff(%MediaItem{} = movie, reason) do
    case Search.record_failure("movie", movie.id, reason) do
      {:ok, backoff} ->
        Logger.info("Applied search backoff for movie",
          media_item_id: movie.id,
          title: movie.title,
          failure_count: backoff.failure_count,
          next_eligible_at: backoff.next_eligible_at,
          reason: reason
        )

        # Emit backoff event
        Events.search_backoff_applied(
          movie,
          reason,
          Search.get_backoff_info("movie", movie.id)
        )

      {:error, changeset} ->
        Logger.error("Failed to record search backoff for movie",
          media_item_id: movie.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp reset_movie_backoff(%MediaItem{} = movie) do
    case Search.get_backoff("movie", movie.id) do
      nil ->
        :ok

      backoff ->
        previous_count = backoff.failure_count
        Search.reset_backoff("movie", movie.id)

        Logger.info("Reset search backoff for movie",
          media_item_id: movie.id,
          title: movie.title,
          previous_failure_count: previous_count
        )

        # Emit backoff reset event
        Events.search_backoff_reset(movie, previous_count)
    end
  end

  ## Private Functions - Event Helpers

  # Build a map of filter statistics for the Activity view. Delegates to the
  # shared ReleaseRanker.build_filter_stats/2 so the movie path now surfaces the
  # same per-result scores, hard-removal reasons, and penalty state the TV path
  # does (previously this used a plain seeder-count heuristic).
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

  # Drops results matching an active `(indexer, guid)` row in the
  # release_blacklist table (#123). The "filter, don't rank" convention
  # keeps this distinct from `ReleaseRanker`. See `Mydia.Downloads.Blacklists`
  # for the batched implementation that issues one DB query regardless of
  # result count.
  defp reject_blacklisted(results, ctx) do
    movie_id = Keyword.get(ctx, :movie) && Keyword.get(ctx, :movie).id
    Blacklists.reject_blacklisted(results, movie_id: movie_id)
  end
end
