defmodule MydiaWeb.MediaLive.Show.SearchHelpers do
  @moduledoc """
  Search-related helper functions for the MediaLive.Show page.
  Handles manual search, filtering, sorting, and result processing.
  """

  alias Mydia.Indexers
  alias Mydia.Indexers.RankingOptions
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.SearchScorer
  alias Mydia.Media

  def generate_result_id(%SearchResult{} = result) do
    # Generate a unique ID based on the download URL and indexer
    # Use :erlang.phash2 to create a stable integer ID from the URL
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  @doc """
  Prepare results for streaming by adding position-based IDs to preserve sort order.
  LiveView streams may reorder items based on DOM IDs, so we include position.
  """
  def prepare_for_stream(sorted_results) do
    sorted_results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      # Add a position field that will be used in the DOM ID
      Map.put(result, :stream_position, index)
    end)
  end

  def generate_positioned_id(%{stream_position: pos} = result) do
    # Include position as a zero-padded prefix to ensure correct ordering
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{String.pad_leading(Integer.to_string(pos), 5, "0")}-#{hash}"
  end

  def generate_positioned_id(result), do: generate_result_id(result)

  def perform_search(query, min_seeders) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true
    ]

    {:ok, %{results: results, indexer_errors: indexer_errors}} =
      Indexers.search_all(query, opts)

    {:ok, results, indexer_errors}
  end

  def apply_search_filters(socket) do
    # Re-filter from raw results without re-searching
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted_results =
      sort_search_results_with_opts(filtered_results, socket.assigns.sort_by, ranking_opts)

    prepared_results = prepare_for_stream(sorted_results)

    socket
    |> Phoenix.Component.assign(:results_empty?, sorted_results == [])
    |> Phoenix.LiveView.stream(:search_results, prepared_results, reset: true)
  end

  def apply_search_sort(socket) do
    # Re-filter and re-sort from raw results
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted_results =
      sort_search_results_with_opts(filtered_results, socket.assigns.sort_by, ranking_opts)

    prepared_results = prepare_for_stream(sorted_results)

    socket
    |> Phoenix.LiveView.stream(:search_results, prepared_results, reset: true)
  end

  def filter_search_results(results, assigns) do
    results
    |> filter_by_seeders(assigns.min_seeders)
    |> filter_by_quality(assigns.quality_filter)
  end

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    # NZB results have nil seeders; the min-seeders setting is torrent-only.
    Enum.filter(results, fn result ->
      is_nil(result.seeders) or result.seeders >= min_seeders
    end)
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

  @doc """
  Sort search results by the specified criteria.

  ## Options

  - `sort_by` - The sorting criteria (`:quality`, `:seeders`, `:size`, `:date`)
  - `quality_profile` - The quality profile to use for scoring (optional)
  - `media_type` - The media type for profile scoring (`:movie` or `:episode`)
  - `search_query` - The original search query for title relevance scoring (optional)
  """
  def sort_search_results(
        results,
        sort_by,
        quality_profile \\ nil,
        media_type \\ :movie,
        search_query \\ nil
      )

  def sort_search_results(results, :quality, nil, _media_type, _search_query) do
    # No quality profile - just sort by seeders (most available first)
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  def sort_search_results(results, :quality, quality_profile, media_type, search_query) do
    # Back-compat 5-arity entry: build minimal ranking options and route through
    # the unified ranker so the manual top result matches automatic selection.
    ranking_opts =
      RankingOptions.build(%{
        quality_profile: quality_profile,
        media_type: media_type,
        search_query: search_query
      })

    quality_sort_via_ranker(results, ranking_opts)
  end

  def sort_search_results(results, :seeders, _quality_profile, _media_type, _search_query) do
    Enum.sort_by(results, & &1.seeders, :desc)
  end

  def sort_search_results(results, :size, _quality_profile, _media_type, _search_query) do
    Enum.sort_by(results, & &1.size, :desc)
  end

  def sort_search_results(results, :date, _quality_profile, _media_type, _search_query) do
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

  @doc """
  Sort manual-search results using a pre-built RankingOptions keyword list.

  For the `:quality` sort mode this routes through `ReleaseRanker.rank_all/2`,
  so the manual top result equals what automatic search would select (R2).
  Penalized releases (size/seeder/identity) remain visible, sorted to the bottom
  (R3); only hard removals (blocked tags, invalid, too-recent NZB) drop out.
  Non-quality sort modes (`:seeders`, `:size`, `:date`) stay as direct sorts.
  """
  def sort_search_results_with_opts(results, :quality, ranking_opts) do
    quality_sort_via_ranker(results, ranking_opts)
  end

  def sort_search_results_with_opts(results, sort_by, ranking_opts) do
    quality_profile = Keyword.get(ranking_opts, :quality_profile)
    media_type = Keyword.get(ranking_opts, :media_type, :movie)
    search_query = Keyword.get(ranking_opts, :search_query)
    sort_search_results(results, sort_by, quality_profile, media_type, search_query)
  end

  # Run the unified ranker and return the surviving SearchResults in ranked
  # order. When no quality profile is set, fall back to a seeders sort (matching
  # the legacy no-profile behavior).
  defp quality_sort_via_ranker(results, ranking_opts) do
    case Keyword.get(ranking_opts, :quality_profile) do
      nil ->
        Enum.sort_by(results, & &1.seeders, :desc)

      _profile ->
        results
        |> ReleaseRanker.rank_all(ranking_opts)
        |> Enum.map(& &1.result)
    end
  end

  @doc """
  Build the shared ranking options for the manual search dialog from the socket
  assigns, deriving the expected title and (for episode/season searches) the
  expected season/episode from the `manual_search_context`.

  Pure field read, no database access: `:effective_quality_profile` must
  already be resolved (via `Mydia.Settings.effective_quality_profile/1`) and
  present in `assigns` before calling this. The key is fetched, not defaulted:
  a caller that forgets it raises rather than silently degrading to "no
  profile", which would quietly reinstate the bare seeders-sort fallback the
  default-profile resolution exists to prevent. Pass an explicit `nil` when no
  profile resolved.
  """
  def build_manual_ranking_opts(assigns) do
    media_item = assigns.media_item
    context = Map.get(assigns, :manual_search_context) || %{type: :media_item}

    {expected_season, expected_episode} = expected_identity(context)

    RankingOptions.build(%{
      quality_profile: Map.fetch!(assigns, :effective_quality_profile),
      media_type: get_media_type(media_item),
      min_seeders: Map.get(assigns, :min_seeders),
      search_query: Map.get(assigns, :manual_search_query),
      expected_title: media_item.title,
      expected_season: expected_season,
      expected_episode: expected_episode
    })
  end

  # Prefer the season/episode the modal already loaded into the context, so
  # re-sorts and modal re-renders don't re-query the episode on every call.
  defp expected_identity(%{type: :episode, season_number: season, episode_number: episode})
       when not is_nil(season) and not is_nil(episode) do
    {season, episode}
  end

  defp expected_identity(%{type: :episode, episode_id: episode_id}) do
    episode = Media.get_episode!(episode_id)
    {episode.season_number, episode.episode_number}
  rescue
    Ecto.NoResultsError -> {nil, nil}
  end

  defp expected_identity(%{type: :season, season_number: season}), do: {season, nil}
  defp expected_identity(_context), do: {nil, nil}

  @doc """
  Calculate profile-based score for a search result.
  Returns the combined score using the unified SearchScorer algorithm.
  """
  def profile_score(%SearchResult{} = result, quality_profile, media_type) do
    opts = [quality_profile: quality_profile, media_type: media_type]
    SearchScorer.score_result(result, opts)
  end

  @doc """
  Build the unified score breakdown for a manual-search result, using the same
  `ReleaseRanker` pipeline (and the same ranking options) that ordered the list.

  Returns a map with:
  - `:score` - The ranker total (may be deeply negative for identity mismatches)
  - `:breakdown` - The `ScoreBreakdown` struct (quality, seeders, size, age,
    title_match, tag_bonus, and the size/seeder/identity penalties)
  - `:detected` - Map of detected quality attributes (for value display)
  - `:violations` - List of constraint violations from the scorer

  Accepts the full ranking options keyword list so penalties (which depend on
  size_range and expected season/episode) match what the ranker computed.
  """
  def profile_score_breakdown(%SearchResult{} = result, ranking_opts)
      when is_list(ranking_opts) do
    breakdown = ReleaseRanker.calculate_score_breakdown(result, ranking_opts)
    scorer = SearchScorer.score_result_with_breakdown(result, ranking_opts)

    %{
      score: breakdown.total,
      breakdown: breakdown,
      detected: scorer.detected,
      violations: scorer.violations
    }
  end

  @doc """
  Back-compat 3-arity breakdown using only the quality profile and media type.
  """
  def profile_score_breakdown(%SearchResult{} = result, quality_profile, media_type) do
    profile_score_breakdown(
      result,
      RankingOptions.build(%{quality_profile: quality_profile, media_type: media_type})
    )
  end

  def get_media_type(media_item) do
    case media_item.type do
      "movie" -> :movie
      "tv_show" -> :episode
      _ -> :movie
    end
  end

  # Helper functions for the search results template

  def get_search_quality_badge(%SearchResult{} = result) do
    SearchResult.quality_description(result)
  end

  def search_health_score(%SearchResult{} = result) do
    SearchResult.health_score(result)
  end
end
