defmodule Mydia.Jobs.MovieUpgradeSearch do
  @moduledoc """
  Background job for searching and downloading quality upgrades for movies.

  Searches indexers for better quality versions of already-downloaded movies
  and initiates upgrade downloads until the quality profile's ceiling
  (`upgrade_until_quality`) is reached.

  Runs on a daily cron schedule. Movies are processed in priority order
  (lowest quality first), capped at `@max_movies_per_run` per cycle.

  ## Examples

      # Queue upgrade search for all monitored movies
      %{"mode" => "all_monitored"}
      |> MovieUpgradeSearch.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :upgrade_search,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Repo, Indexers, Events, Search}
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Search.Pipeline
  alias Mydia.Settings.{QualityMatcher, QualityProfile}

  @max_movies_per_run 25
  @actor_id "movie_upgrade_search"

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_monitored"}}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting automatic upgrade search for monitored movies")

    movies = load_upgrade_candidates()
    total_eligible = length(movies)
    movies_to_process = Enum.take(movies, @max_movies_per_run)
    processing_count = length(movies_to_process)

    Logger.info(
      "Found #{total_eligible} movies eligible for upgrade, processing #{processing_count}"
    )

    if processing_count == 0 do
      :ok
    else
      results =
        Enum.map(movies_to_process, fn {movie, current_file, profile} ->
          result = search_upgrade(movie, current_file, profile)
          Pipeline.apply_search_delay()
          result
        end)

      upgraded = Enum.count(results, &(&1 == :upgraded))
      no_upgrade = Enum.count(results, &(&1 == :no_upgrade))
      failed = Enum.count(results, &match?({:error, _}, &1))
      duration = System.monotonic_time(:millisecond) - start_time

      Logger.info("Upgrade search completed",
        duration_ms: duration,
        total_eligible: total_eligible,
        processed: processing_count,
        upgraded: upgraded,
        no_upgrade: no_upgrade,
        failed: failed
      )

      :ok
    end
  end

  ## Private Functions - Candidate Loading

  @doc false
  def load_upgrade_candidates do
    # Find monitored movies that have files and whose quality profile allows upgrades
    movies =
      from(mi in MediaItem,
        where: mi.type == "movie" and mi.monitored == true,
        where: not is_nil(mi.quality_profile_id),
        join: qp in QualityProfile,
        on: qp.id == mi.quality_profile_id,
        where: qp.upgrades_allowed == true,
        join: mf in MediaFile,
        on: mf.media_item_id == mi.id and is_nil(mf.trashed_at),
        preload: [quality_profile: qp, media_files: mf]
      )
      |> Repo.all()
      # Deduplicate since join can produce multiple rows per movie
      |> Enum.uniq_by(& &1.id)

    movies
    |> Enum.map(fn movie ->
      profile = movie.quality_profile
      best_file = best_quality_file(movie.media_files, profile)
      {movie, best_file, profile}
    end)
    |> Enum.filter(fn {_movie, best_file, profile} ->
      best_file != nil && file_below_ceiling?(best_file, profile)
    end)
    |> filter_in_backoff()
    # Sort by lowest quality first (most in need of upgrade)
    |> Enum.sort_by(fn {_movie, file, _profile} -> quality_level(file.resolution) end)
  end

  defp best_quality_file(files, profile) do
    files
    |> Enum.filter(&is_nil(&1.trashed_at))
    |> Enum.max_by(
      fn file ->
        media_attrs = file_to_media_attrs(file)
        %{score: score} = QualityProfile.score_media_file(profile, media_attrs)
        score
      end,
      fn -> nil end
    )
  end

  defp file_below_ceiling?(_file, %QualityProfile{upgrade_until_quality: nil}), do: true

  defp file_below_ceiling?(file, %QualityProfile{upgrade_until_quality: ceiling}) do
    quality_level(file.resolution) < quality_level(ceiling)
  end

  defp filter_in_backoff(candidates) do
    {eligible, in_backoff} =
      Enum.split_with(candidates, fn {movie, _file, _profile} ->
        Search.eligible?("movie", movie.id)
      end)

    if in_backoff != [] do
      Logger.info("Skipping #{length(in_backoff)} movies in backoff for upgrade search")
    end

    eligible
  end

  ## Private Functions - Search & Upgrade

  defp search_upgrade(movie, current_file, profile) do
    query = Pipeline.build_search_query(movie)
    min_seeders = Pipeline.get_min_seeders()

    Logger.info("Searching for upgrade",
      media_item_id: movie.id,
      title: movie.title,
      current_resolution: current_file.resolution,
      query: query
    )

    case Indexers.search_all(query, min_seeders: min_seeders) do
      {:ok, %{results: [], indexer_errors: indexer_errors}} ->
        if indexer_errors != [] do
          Logger.warning("Upgrade search failed due to indexer errors",
            media_item_id: movie.id,
            title: movie.title,
            query: query,
            errors: inspect(indexer_errors)
          )
        end

        record_backoff(movie, "no_results")
        :no_upgrade

      {:ok, %{results: results}} ->
        find_and_download_upgrade(movie, current_file, profile, results, query)
    end
  end

  defp find_and_download_upgrade(movie, current_file, profile, results, query) do
    ranking_opts = Pipeline.build_ranking_options(movie, media_type: :movie)

    # Compute current file's composite score for same-resolution comparison
    current_score = compute_file_score(current_file, profile)

    # Filter to only results that are genuine upgrades
    upgrade_results =
      results
      |> Enum.filter(fn result ->
        QualityMatcher.is_upgrade?(result, profile, current_file.resolution, current_score)
      end)

    if upgrade_results == [] do
      record_backoff(movie, "no_upgrade_available")

      Events.search_no_results(
        movie,
        %{
          "query" => query,
          "indexers_searched" => Pipeline.count_enabled_indexers()
        },
        actor_id: @actor_id
      )

      :no_upgrade
    else
      # Rank the upgrade candidates and pick the best
      case ReleaseRanker.select_best_result(upgrade_results, ranking_opts) do
        nil ->
          record_backoff(movie, "all_filtered")
          :no_upgrade

        %{result: best_result, score: score, breakdown: breakdown} ->
          # TOCTOU re-check: verify file hasn't been upgraded since we started
          case toctou_recheck(movie, current_file, profile) do
            :still_eligible ->
              attempt_upgrade_download(movie, best_result, score, breakdown, query, results)

            :no_longer_eligible ->
              Logger.info("Movie no longer eligible for upgrade (TOCTOU check)",
                media_item_id: movie.id,
                title: movie.title
              )

              :no_upgrade
          end
      end
    end
  end

  defp attempt_upgrade_download(movie, best_result, score, breakdown, query, results) do
    Logger.info("Found upgrade for movie",
      media_item_id: movie.id,
      title: movie.title,
      result_title: best_result.title,
      score: score
    )

    Events.search_completed(
      movie,
      %{
        "query" => query,
        "results_count" => length(results),
        "selected_release" => best_result.title,
        "score" => score,
        "breakdown" => Pipeline.stringify_keys(breakdown)
      },
      actor_id: @actor_id
    )

    case Pipeline.initiate_download(movie, best_result, download_reason: :upgrade) do
      {:ok, _download} ->
        reset_backoff(movie)

        Logger.info("Initiated upgrade download for movie",
          media_item_id: movie.id,
          title: movie.title,
          result_title: best_result.title
        )

        :upgraded

      {:error, reason} ->
        Logger.error("Failed to initiate upgrade download",
          media_item_id: movie.id,
          title: movie.title,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions - TOCTOU Protection

  defp toctou_recheck(movie, original_file, profile) do
    # Re-query the movie's current best file to check if it's still eligible
    current_files =
      from(mf in MediaFile,
        where: mf.media_item_id == ^movie.id and is_nil(mf.trashed_at)
      )
      |> Repo.all()

    best_file = best_quality_file(current_files, profile)

    cond do
      # No files anymore (deleted while we searched)
      best_file == nil -> :no_longer_eligible
      # Best file changed (new file appeared)
      best_file.id != original_file.id -> :no_longer_eligible
      # File no longer below ceiling
      !file_below_ceiling?(best_file, profile) -> :no_longer_eligible
      # Still eligible
      true -> :still_eligible
    end
  end

  ## Private Functions - Scoring

  defp compute_file_score(file, profile) do
    media_attrs = file_to_media_attrs(file)
    %{score: score} = QualityProfile.score_media_file(profile, media_attrs)
    score
  end

  defp file_to_media_attrs(%MediaFile{} = file) do
    %{
      video_codec: QualityMatcher.normalize_codec(file.codec),
      audio_codec: QualityMatcher.normalize_codec(file.audio_codec),
      resolution: file.resolution,
      source: nil,
      file_size_mb: if(file.size, do: file.size / (1024 * 1024), else: nil),
      media_type: :movie,
      hdr_format: file.hdr_format
    }
  end

  ## Private Functions - Backoff

  defp record_backoff(movie, reason) do
    case Search.record_failure("movie", movie.id, reason) do
      {:ok, backoff} ->
        Logger.info("Applied upgrade search backoff",
          media_item_id: movie.id,
          failure_count: backoff.failure_count,
          reason: reason
        )

        Events.search_backoff_applied(
          movie,
          reason,
          Search.get_backoff_info("movie", movie.id),
          actor_id: @actor_id
        )

      {:error, _changeset} ->
        Logger.error("Failed to record upgrade search backoff",
          media_item_id: movie.id
        )
    end
  end

  defp reset_backoff(movie) do
    case Search.get_backoff("movie", movie.id) do
      nil ->
        :ok

      backoff ->
        previous_count = backoff.failure_count
        Search.reset_backoff("movie", movie.id)

        Logger.info("Reset upgrade search backoff",
          media_item_id: movie.id,
          previous_failure_count: previous_count
        )

        Events.search_backoff_reset(movie, previous_count, actor_id: @actor_id)
    end
  end

  ## Private Functions - Quality Level

  defp quality_level(resolution), do: QualityMatcher.quality_level(resolution)
end
