defmodule Mydia.Indexers.RankingOptions do
  @moduledoc """
  Builds the shared keyword-list options consumed by `ReleaseRanker.rank_all/2`.

  Both the automatic search jobs (movie and TV) and the manual search dialog
  thread their ranking options through this one builder so the two paths cannot
  drift apart again. Previously each job hand-rolled near-duplicate
  `build_ranking_options` / `extract_size_range` / `build_quality_options`
  helpers that diverged subtly (e.g. the `min_ratio` source).

  ## min_ratio source (resolved)

  The movie job historically read `min_ratio` from `profile.rules` while the TV
  job read it from `profile.quality_standards`. This builder reads `min_ratio`
  from **`quality_standards`** (accepting both atom and string keys), the source
  the schema actually populates. The movie path's old `rules` source is dropped;
  a profile that only set `min_ratio` under `rules` no longer affects ranking.

  ## preferred_qualities ordering (stored order is not authoritative)

  `ReleaseRanker` treats the *position* of a resolution in `:preferred_qualities`
  as the primary sort key, with score only a tie-break: index 0 wins. Profiles,
  however, store `preferred_resolutions` ascending — the shipped "Any" preset is
  `["360p", ..., "2160p"]`, and the Admin editor renders its checkboxes
  ascending, so HTML array params come back ascending too. Handing that stored
  order straight to the ranker made every multi-resolution profile grab the
  *lowest* resolution available.

  So this builder sorts `:preferred_qualities` into descending quality order
  before handing it over, using `Mydia.Settings.QualityProfile.valid_resolutions/0`
  as the canonical ordering. Resolutions outside that vocabulary sort last, in
  a stable alphabetical order, rather than crashing. The upshot: the order a
  profile happens to store its resolutions in does not decide what gets grabbed.

  ## Profile resolution (do not reimplement here)

  This builder takes an already-resolved `%QualityProfile{}` or `nil` and stays
  free of database access. Deciding *which* profile governs an item, including
  the fallback to the configured default when the item has none of its own, is
  `Mydia.Indexers.QualityProfileResolver`. Call sites must resolve through
  that function rather than reading `media_item.quality_profile` directly,
  otherwise the fallback drifts out of one search path the way `min_ratio` did.

  ## Custom formats (resolved upstream)

  `:custom_formats` arrives already resolved and compiled from
  `Mydia.Settings.CustomFormats.resolve_for_profile/1`. Resolution stays
  outside this module so it remains database-free; call sites pass the
  resolved list in the input map and this builder threads it through.
  """

  alias Mydia.Settings.QualityProfile

  require Logger

  @type media_type :: :movie | :episode

  @type input :: %{
          optional(:quality_profile) => QualityProfile.t() | nil,
          required(:media_type) => media_type(),
          optional(:min_seeders) => non_neg_integer() | nil,
          optional(:size_range) => {number() | nil, number() | nil} | nil,
          optional(:search_query) => String.t() | nil,
          optional(:expected_title) => String.t() | nil,
          optional(:expected_season) => non_neg_integer() | nil,
          optional(:expected_episode) => non_neg_integer() | nil,
          optional(:blocked_tags) => [String.t()] | nil,
          optional(:preferred_tags) => [String.t()] | nil,
          optional(:custom_formats) => [map()] | nil
        }

  @doc """
  Build the ranking-options keyword list from a map of inputs.

  Required: `:media_type`. Everything else is optional; nil/empty values are
  skipped (mirroring the jobs' `maybe_add_option/3` behavior) so the penalty
  math and downstream consumers never receive nils.
  """
  @spec build(input()) :: keyword()
  def build(%{media_type: media_type} = input) do
    quality_profile = Map.get(input, :quality_profile)

    base_opts =
      [media_type: media_type]
      # Skip nil scalar keys so the penalty math and downstream consumers never
      # see them. Omitting :min_seeders when nil lets the ranker's default (0)
      # apply; an explicit nil would break the seeder-minimum comparison.
      |> maybe_put(:size_range, Map.get(input, :size_range))
      |> maybe_put(:search_query, Map.get(input, :search_query))
      |> maybe_put(:expected_title, Map.get(input, :expected_title))
      |> maybe_put(:min_seeders, Map.get(input, :min_seeders))
      |> maybe_put(:expected_season, Map.get(input, :expected_season))
      |> maybe_put(:expected_episode, Map.get(input, :expected_episode))

    opts_with_quality =
      case quality_profile do
        %QualityProfile{} = profile ->
          warn_on_missing_custom_formats(input)

          base_opts
          |> Keyword.put(:quality_profile, profile)
          |> Keyword.merge(build_quality_options(profile, media_type))

        _ ->
          base_opts
      end

    opts_with_quality
    |> maybe_add_option(:blocked_tags, Map.get(input, :blocked_tags))
    |> maybe_add_option(:preferred_tags, Map.get(input, :preferred_tags))
    |> maybe_add_option(:custom_formats, Map.get(input, :custom_formats))
  end

  # Six call sites build ranking options, and a forgotten one would silently
  # ignore every custom format for that search path. That is exactly the drift
  # this module's moduledoc exists to prevent, so an absent key is loud. An
  # explicitly empty list is silent: it means "resolved, nothing scored".
  defp warn_on_missing_custom_formats(input) do
    unless Map.has_key?(input, :custom_formats) do
      Logger.warning(
        "[RankingOptions] built with a quality profile but no :custom_formats key; " <>
          "custom formats will be ignored for this search"
      )
    end
  end

  @doc """
  Extract `:preferred_qualities`, `:min_ratio`, and `:size_range` from a quality
  profile for the given media type. `:preferred_qualities` is sourced from
  `quality_standards.preferred_resolutions` and re-sorted into descending
  quality order (see the moduledoc: the ranker reads position as priority, and
  profiles store their resolutions ascending).
  """
  @spec build_quality_options(QualityProfile.t(), media_type()) :: keyword()
  def build_quality_options(%QualityProfile{} = quality_profile, media_type) do
    quality_opts =
      case QualityProfile.preferred_resolutions(quality_profile) do
        [] -> []
        resolutions -> [preferred_qualities: sort_by_quality_desc(resolutions)]
      end

    ratio_opts = extract_min_ratio(quality_profile)
    size_opts = extract_size_range(quality_profile, media_type)

    quality_opts
    |> Keyword.merge(ratio_opts)
    |> Keyword.merge(size_opts)
  end

  # Order resolutions best-first. The canonical vocabulary is ascending, so a
  # known resolution sorts on its negated index (highest quality first) and an
  # unrecognized one sorts after every known resolution, ordered by its own
  # value so the result stays deterministic instead of crashing.
  defp sort_by_quality_desc(resolutions) do
    canonical = QualityProfile.valid_resolutions()

    Enum.sort_by(resolutions, fn resolution ->
      case Enum.find_index(canonical, &(&1 == resolution)) do
        nil -> {1, to_string(resolution)}
        index -> {0, -index}
      end
    end)
  end

  # Single source of truth for min_ratio: quality_standards (atom or string key).
  defp extract_min_ratio(%QualityProfile{quality_standards: standards}) do
    case standards do
      %{min_ratio: min_ratio} when is_number(min_ratio) -> [min_ratio: min_ratio]
      %{"min_ratio" => min_ratio} when is_number(min_ratio) -> [min_ratio: min_ratio]
      _ -> []
    end
  end

  @doc """
  Extract the `:size_range` option from a profile's quality standards based on
  media type. Returns `[]` (omitting the option) when no bounds are set, so the
  penalty math never receives nil-only ranges.
  """
  @spec extract_size_range(QualityProfile.t() | map(), media_type()) :: keyword()
  def extract_size_range(%{quality_standards: standards}, media_type) when is_map(standards) do
    {min_key, max_key} =
      case media_type do
        :movie -> {:movie_min_size_mb, :movie_max_size_mb}
        :episode -> {:episode_min_size_mb, :episode_max_size_mb}
      end

    min_size = Map.get(standards, min_key)
    max_size = Map.get(standards, max_key)

    case {min_size, max_size} do
      {nil, nil} -> []
      {min, nil} when is_number(min) -> [size_range: {min, nil}]
      {nil, max} when is_number(max) -> [size_range: {nil, max}]
      {min, max} when is_number(min) and is_number(max) -> [size_range: {min, max}]
      _ -> []
    end
  end

  def extract_size_range(_, _), do: []

  # Skip nil/empty list option values so the penalty math and downstream
  # consumers never see them.
  defp maybe_add_option(opts, _key, nil), do: opts
  defp maybe_add_option(opts, _key, []), do: opts
  defp maybe_add_option(opts, key, value), do: Keyword.put(opts, key, value)

  # Put a non-nil scalar option (used for expected_season/expected_episode).
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
