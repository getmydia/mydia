defmodule MydiaWeb.MediaLive.Show.SearchHelpers do
  @moduledoc """
  Search-related helper functions for the MediaLive.Show page.
  Handles manual search, filtering, sorting, and result processing.
  """

  alias Mydia.Indexers
  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Indexers.RankingOptions
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.SearchScorer
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Media
  alias Mydia.Settings.CustomFormats

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

  @doc """
  Rebuild the `:search_results` stream from a freshly sorted list, re-applying
  the per-row grab state held in `:result_states`.

  Per-row flags (`:downloading`, `:downloaded`, `:duplicate`, `:grab_failed`)
  are written into the stream by `SearchEvents.mark_result/3` and live nowhere
  else, so every `reset: true` rebuild would erase them. That used to be
  unreachable: results were only clickable once the search had finished, and
  nothing rebuilt the stream after that. Now that results stream in while slow
  indexers are still running, a user can grab a release and watch the badge
  vanish the moment the next indexer reports.

  `:result_states` is the backing assign that survives those rebuilds, mirroring
  how `MydiaWeb.SearchLive.Index` keeps `:downloading_urls` in assigns and
  re-derives per-row state after each re-stream.
  """
  def stream_prepared_results(socket, sorted_results) do
    states = Map.get(socket.assigns, :result_states, %{})

    prepared =
      sorted_results
      |> prepare_for_stream()
      |> Enum.map(fn result ->
        case Map.get(states, result.download_url) do
          nil -> result
          state -> Map.merge(result, state)
        end
      end)

    Phoenix.LiveView.stream(socket, :search_results, prepared, reset: true)
  end

  @doc """
  Run a manual search, streaming per-indexer progress back to `lv`.

  `indexer_ids` scopes the search to a subset of the enabled indexers. It
  defaults to `nil`, which searches all of them; the single-indexer retry
  passes `[indexer_id]` so retrying one failed chip does not re-run (and
  re-set to `:pending`) every other indexer. `Indexers.search_all/2` treats a
  `nil` value the same as the option being absent.
  """
  def perform_search(query, min_seeders, lv, search_id, indexer_ids \\ nil) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true,
      indexer_ids: indexer_ids,
      on_start: fn pending -> send(lv, {:indexer_search_started, search_id, pending}) end,
      on_indexer_result: fn progress -> send(lv, {:indexer_progress, search_id, progress}) end
    ]

    case Indexers.search_all(query, opts) do
      {:ok, %{results: results, indexer_errors: indexer_errors}} ->
        {:ok, results, indexer_errors}

      other ->
        {:error, other}
    end
  end

  @doc """
  Folds one indexer's results into the accumulated set and re-ranks everything,
  so the list stays correctly ordered as indexers report out of order.

  Two collections are kept deliberately, and must NOT be collapsed into one:

    - `:indexer_raw_results` - every release seen so far this search, keyed by
      `download_url`, UNTRUNCATED. This is what future progress messages fold
      new results onto.
    - `:raw_search_results` - the ranked-and-deduplicated (and therefore
      truncated-to-max_results) set, matching what `handle_search_async/2`
      assigns at the end of a search. `apply_search_filters/1` re-filters
      straight from it without deduplicating, so it must stay deduplicated.

  Folding new results directly onto `:raw_search_results` (rather than a
  separate untruncated pool) would corrupt deduplication across rounds: an
  item can be evicted by `rank_and_dedupe/3`'s `max_results` truncation while
  it was the sole member of its dedup group, having never lost a dedup
  comparison. If a WEAKER duplicate of that same release arrives in a later
  round, deduping against the truncated set would only see the weak
  duplicate (the true winner already evicted) and crown it as the group's
  representative. Re-ranking from the full untruncated pool every round
  means deduplication always compares every variant of a release ever seen,
  so the strongest one always wins.

  `results` is cleared from the stored progress struct before it's put in
  `:indexer_progress`, because it can be large and the releases already live
  in `:indexer_raw_results`.
  """
  def apply_indexer_progress(socket, %IndexerProgress{} = progress) do
    indexer_progress =
      Map.put(socket.assigns.indexer_progress, progress.indexer_id, %{progress | results: []})

    raw_pool =
      Enum.reduce(progress.results, socket.assigns.indexer_raw_results, fn result, acc ->
        Map.put(acc, result.download_url, result)
      end)

    ranked =
      raw_pool
      |> Map.values()
      |> Indexers.rank_and_dedupe(socket.assigns.manual_search_query,
        min_seeders: socket.assigns.min_seeders
      )

    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted =
      ranked
      |> filter_search_results(socket.assigns)
      |> sort_search_results_with_opts(socket.assigns.sort_by, ranking_opts)

    socket
    |> Phoenix.Component.assign(:indexer_progress, indexer_progress)
    |> Phoenix.Component.assign(:indexer_raw_results, raw_pool)
    |> Phoenix.Component.assign(:raw_search_results, ranked)
    |> Phoenix.Component.assign(:results_empty?, sorted == [])
    |> stream_prepared_results(sorted)
  end

  def apply_search_filters(socket) do
    # Re-filter from raw results without re-searching
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted_results =
      sort_search_results_with_opts(filtered_results, socket.assigns.sort_by, ranking_opts)

    socket
    |> Phoenix.Component.assign(:results_empty?, sorted_results == [])
    |> stream_prepared_results(sorted_results)
  end

  def apply_search_sort(socket) do
    # Re-filter and re-sort from raw results
    results = Map.get(socket.assigns, :raw_search_results, [])
    filtered_results = filter_search_results(results, socket.assigns)
    ranking_opts = build_manual_ranking_opts(socket.assigns)

    sorted_results =
      sort_search_results_with_opts(filtered_results, socket.assigns.sort_by, ranking_opts)

    stream_prepared_results(socket, sorted_results)
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
        custom_formats: CustomFormats.resolve_for_profile(quality_profile),
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
  so the manual top result equals what automatic search would select (R2),
  with one deliberate exception: `quality_sort_via_ranker/2` passes
  `apply_source_exclusion: false`, so a profile's `:excluded_sources` list is
  NOT enforced here. Per spec R8, manual search and manual grab are the
  operator's explicit escape hatch and must stay unaffected by exclusion the
  automatic path applies — silently dropping a release from the manual
  dialog, recoverable only by switching sort mode, would remove that escape
  hatch. Penalized releases (size/seeder/identity) remain visible, sorted to
  the bottom (R3); the hard removals that still apply to manual search are
  blocked tags, invalid releases, and too-recent NZBs.
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
  #
  # apply_source_exclusion: false is load-bearing (R8): this is the manual
  # search dialog, and manual search/grab must never silently drop a release
  # because of a profile's :excluded_sources list, even though a resolved
  # profile IS passed through for scoring/sorting. The opt-out is an explicit
  # flag rather than "no profile present" so it can't be defeated by the
  # profile the manual dialog legitimately does pass.
  defp quality_sort_via_ranker(results, ranking_opts) do
    case Keyword.get(ranking_opts, :quality_profile) do
      nil ->
        Enum.sort_by(results, & &1.seeders, :desc)

      _profile ->
        results
        |> ReleaseRanker.rank_all(Keyword.put(ranking_opts, :apply_source_exclusion, false))
        |> Enum.map(& &1.result)
    end
  end

  @doc """
  Build the shared ranking options for the manual search dialog from the socket
  assigns, deriving the expected title and (for episode/season searches) the
  expected season/episode from the `manual_search_context`.

  The profile is resolved through `Mydia.Indexers.QualityProfileResolver`, so
  the item's own profile, the instance default, and `nil` are decided in one
  place for every search path.
  """
  def build_manual_ranking_opts(assigns) do
    media_item = assigns.media_item
    context = Map.get(assigns, :manual_search_context) || %{type: :media_item}

    {expected_season, expected_episode} = expected_identity(context)

    profile = QualityProfileResolver.resolve(media_item)

    RankingOptions.build(%{
      quality_profile: profile,
      custom_formats: CustomFormats.resolve_for_profile(profile),
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
      RankingOptions.build(%{
        quality_profile: quality_profile,
        custom_formats: CustomFormats.resolve_for_profile(quality_profile),
        media_type: media_type
      })
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
