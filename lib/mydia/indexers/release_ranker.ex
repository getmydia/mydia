defmodule Mydia.Indexers.ReleaseRanker do
  @moduledoc """
  Ranks and filters torrent search results based on configurable criteria.

  This module provides a pluggable ranking system for selecting the best
  torrent releases from search results. It scores releases based on multiple
  factors including quality, seeders, file size, and age.

  ## Usage

      # Get the best result
      ReleaseRanker.select_best_result(results, min_seeders: 10)

      # Rank all results with scores
      ReleaseRanker.rank_all(results, preferred_qualities: ["1080p", "720p"])

      # Filter by criteria
      ReleaseRanker.filter_acceptable(results, size_range: {500, 10_000})

  ## Scoring Factors

  - **Quality** (60% weight): Resolution, source, codec via `QualityParser`
  - **Seeders** (25% weight): Logarithmic scale with diminishing returns
  - **Size** (10% weight): Bell curve favoring reasonable sizes
  - **Age** (5% weight): Slight preference for newer releases

  ## Options

  - `:min_seeders` - Minimum seeder count (default: 5)
  - `:size_range` - `{min_mb, max_mb}` tuple (default: `{100, 20_000}`)
  - `:preferred_qualities` - List of resolutions in preference order
  - `:blocked_tags` - List of strings to filter out from titles
  - `:preferred_tags` - List of strings that boost scores
  """

  alias Mydia.Indexers.{QualityParser, SearchResult}
  alias Mydia.Indexers.Structs.{RankedResult, ScoreBreakdown}

  @type ranked_result :: RankedResult.t()
  @type score_breakdown :: ScoreBreakdown.t()

  @type ranking_options :: [
          min_seeders: non_neg_integer(),
          size_range: {non_neg_integer(), non_neg_integer()},
          preferred_qualities: [String.t()],
          blocked_tags: [String.t()],
          preferred_tags: [String.t()]
        ]

  @default_min_seeders 5
  @default_size_range {100, 20_000}

  @doc """
  Selects the best result from a list based on ranking criteria.

  Returns the result with the highest score along with its score breakdown.
  Returns `nil` if no results pass the filtering criteria.

  ## Examples

      iex> ReleaseRanker.select_best_result(results, min_seeders: 10)
      %{result: %SearchResult{...}, score: 850.5, breakdown: %{...}}

      iex> ReleaseRanker.select_best_result([], [])
      nil
  """
  @spec select_best_result([SearchResult.t()], ranking_options()) :: ranked_result() | nil
  def select_best_result(results, opts \\ []) do
    results
    |> rank_all(opts)
    |> List.first()
  end

  @doc """
  Ranks all results by score in descending order.

  Returns a list of maps containing the result, total score, and score breakdown.
  Results that don't meet filtering criteria are excluded.

  ## Examples

      iex> ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      [
        %{result: %SearchResult{...}, score: 850.5, breakdown: %{quality: 480, seeders: 200, ...}},
        %{result: %SearchResult{...}, score: 720.3, breakdown: %{quality: 400, seeders: 180, ...}}
      ]
  """
  @spec rank_all([SearchResult.t()], ranking_options()) :: [ranked_result()]
  def rank_all(results, opts \\ []) do
    preferred_qualities = Keyword.get(opts, :preferred_qualities)

    results
    |> filter_acceptable(opts)
    |> Enum.map(fn result ->
      breakdown = calculate_score_breakdown(result, opts)
      RankedResult.new(%{result: result, score: breakdown.total, breakdown: breakdown})
    end)
    |> sort_by_score_and_preferences(preferred_qualities)
  end

  @doc """
  Filters results to only those meeting minimum criteria.

  Removes results that:
  - Have fewer than `:min_seeders` seeders
  - Fall outside the `:size_range` (in MB)
  - Contain any `:blocked_tags` in their title

  ## Examples

      iex> ReleaseRanker.filter_acceptable(results, min_seeders: 10, blocked_tags: ["CAM"])
      [%SearchResult{...}, ...]
  """
  @spec filter_acceptable([SearchResult.t()], ranking_options()) :: [SearchResult.t()]
  def filter_acceptable(results, opts \\ []) do
    min_seeders = Keyword.get(opts, :min_seeders, @default_min_seeders)
    size_range = Keyword.get(opts, :size_range, @default_size_range)
    blocked_tags = Keyword.get(opts, :blocked_tags, [])

    results
    |> Enum.filter(&meets_seeder_minimum?(&1, min_seeders))
    |> Enum.filter(&within_size_range?(&1, size_range))
    |> Enum.filter(&not_blocked?(&1, blocked_tags))
  end

  ## Private Functions - Filtering

  defp meets_seeder_minimum?(%SearchResult{seeders: seeders}, min_seeders) do
    seeders >= min_seeders
  end

  defp within_size_range?(%SearchResult{size: size_bytes}, {min_mb, max_mb}) do
    size_mb = bytes_to_mb(size_bytes)
    size_mb >= min_mb && size_mb <= max_mb
  end

  defp not_blocked?(%SearchResult{title: title}, blocked_tags) do
    title_lower = String.downcase(title)

    not Enum.any?(blocked_tags, fn tag ->
      String.contains?(title_lower, String.downcase(tag))
    end)
  end

  ## Private Functions - Scoring

  defp calculate_score_breakdown(%SearchResult{} = result, opts) do
    quality_score = score_quality(result, opts)
    seeder_score = score_seeders(result.seeders)
    size_score = score_size(result.size)
    age_score = score_age(result.published_at)
    tag_bonus = score_tags(result.title, opts)

    # Weighted scoring
    # Quality: 60%, Seeders: 25%, Size: 10%, Age: 5%
    total =
      quality_score * 0.6 +
        seeder_score * 0.25 +
        size_score * 0.1 +
        age_score * 0.05 +
        tag_bonus

    ScoreBreakdown.new(%{
      quality: round_score(quality_score),
      seeders: round_score(seeder_score),
      size: round_score(size_score),
      age: round_score(age_score),
      tag_bonus: round_score(tag_bonus),
      total: round_score(total)
    })
  end

  defp score_quality(%SearchResult{quality: nil}, _opts), do: 0.0

  defp score_quality(%SearchResult{quality: quality}, opts) do
    base_score = QualityParser.quality_score(quality) |> min(2000) |> max(0) |> to_float()

    # Apply preferred quality boost if specified
    case Keyword.get(opts, :preferred_qualities) do
      nil ->
        base_score

      preferred_qualities ->
        apply_quality_preference_boost(quality, preferred_qualities, base_score)
    end
  end

  defp apply_quality_preference_boost(quality, preferred_qualities, base_score) do
    case quality.resolution do
      nil ->
        base_score

      resolution ->
        # Find the index of this resolution in the preference list
        case Enum.find_index(preferred_qualities, &(&1 == resolution)) do
          nil ->
            # Not in preferred list, apply small penalty
            base_score * 0.9

          index ->
            # In preferred list, boost based on position
            # First preference gets highest boost
            boost = 1.0 + (length(preferred_qualities) - index) * 0.05
            base_score * boost
        end
    end
  end

  defp score_seeders(seeders) when seeders <= 0, do: 0.0

  defp score_seeders(seeders) do
    # Logarithmic scale with diminishing returns
    # 1 seeder ≈ 0, 10 seeders ≈ 100, 100 seeders ≈ 200, 1000 seeders ≈ 300
    base = :math.log10(seeders) * 100

    # Cap at 500 to prevent seeder count from dominating
    min(base, 500.0)
  end

  defp score_size(size_bytes) do
    size_mb = bytes_to_mb(size_bytes)

    # Bell curve favoring 2-15 GB range for movies/episodes
    # Peak score around 5 GB
    cond do
      size_mb < 100 ->
        # Very small files - likely low quality or fake
        0.0

      size_mb < 1000 ->
        # Under 1 GB - could be episodes or low quality
        size_mb / 10.0

      size_mb < 5000 ->
        # 1-5 GB - good quality range
        100.0

      size_mb < 15_000 ->
        # 5-15 GB - excellent quality but larger
        100.0 - (size_mb - 5000) / 200.0

      size_mb < 25_000 ->
        # 15-25 GB - very large but acceptable for 4K
        50.0 - (size_mb - 15_000) / 500.0

      true ->
        # Over 25 GB - penalize heavily
        10.0
    end
  end

  defp score_age(nil), do: 50.0

  defp score_age(%DateTime{} = published_at) do
    now = DateTime.utc_now()
    age_days = DateTime.diff(now, published_at, :day)

    cond do
      age_days < 0 ->
        # Future date (shouldn't happen) - neutral score
        50.0

      age_days <= 7 ->
        # Very recent - highest age score
        100.0

      age_days <= 30 ->
        # Within a month - good
        90.0

      age_days <= 90 ->
        # Within 3 months - decent
        80.0

      age_days <= 365 ->
        # Within a year - neutral
        50.0

      true ->
        # Older than a year - slight penalty
        30.0
    end
  end

  defp score_tags(title, opts) do
    preferred_tags = Keyword.get(opts, :preferred_tags, [])

    if preferred_tags == [] do
      0.0
    else
      title_lower = String.downcase(title)

      preferred_tags
      |> Enum.count(fn tag ->
        String.contains?(title_lower, String.downcase(tag))
      end)
      |> Kernel.*(25.0)
    end
  end

  ## Private Functions - Sorting

  defp sort_by_score_and_preferences(ranked_results, nil) do
    Enum.sort_by(ranked_results, & &1.score, :desc)
  end

  defp sort_by_score_and_preferences(ranked_results, preferred_qualities) do
    ranked_results
    |> Enum.sort_by(fn %{result: result, score: score} ->
      quality_index = quality_preference_index(result, preferred_qualities)
      # Sort by: quality preference (lower index = higher priority), then score
      {quality_index, -score}
    end)
  end

  defp quality_preference_index(%SearchResult{quality: nil}, _preferred_qualities) do
    999
  end

  defp quality_preference_index(%SearchResult{quality: quality}, preferred_qualities) do
    case quality.resolution do
      nil ->
        999

      resolution ->
        case Enum.find_index(preferred_qualities, &(&1 == resolution)) do
          nil -> 999
          index -> index
        end
    end
  end

  ## Private Functions - Helpers

  defp bytes_to_mb(bytes) when is_integer(bytes) do
    bytes / (1024 * 1024)
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp round_score(value) when is_float(value), do: Float.round(value, 2)
  defp round_score(value) when is_integer(value), do: value * 1.0
end
