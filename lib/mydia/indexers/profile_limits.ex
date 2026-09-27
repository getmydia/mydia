defmodule Mydia.Indexers.ProfileLimits do
  @moduledoc """
  The quality-profile settings that are limits rather than preferences, applied
  to search results.

  A setting that constrains the resulting file and is phrased as a limit (min,
  max, require, exclude) is hard. There is no minimum score before an automatic
  grab, so a release that is only scored down is still grabbed whenever it tops
  a list of bad releases, and only removing it keeps it out. A 1080p profile took
  a 360p XviD this way, and an episode profile with a size floor took episodes
  far below it.

  `reject/2` removes violating releases unless the caller passes
  `apply_profile_limits: false`. Manual search does: a manual grab is the
  operator's escape hatch, so the release stays listed and `ReleaseRanker`
  records the reason on `ScoreBreakdown.limit_violation`.

  `Mydia.Settings.QualityProfile.score_media_file/2` treats the same limits as
  violations for a file on disk, which makes a file that breaks one eligible for
  upgrade. `lib/mydia/indexers/README.md` ("Limits vs preferences") states the
  rule, and `test/mydia/indexers/profile_limits_test.exs` holds every
  `quality_standards` key to it.
  """

  require Logger

  alias Mydia.Indexers.{QualityParser, RankingOptions, SearchResult}
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.{ParsedFileInfo, Quality}
  alias Mydia.Quality.Sources
  alias Mydia.Settings.QualityProfile

  @bytes_per_mb 1_048_576

  @limit_keys [
    :excluded_sources,
    :min_resolution,
    :max_resolution,
    :require_hdr,
    :movie_min_size_mb,
    :movie_max_size_mb,
    :episode_min_size_mb,
    :episode_max_size_mb
  ]

  # min_ratio is a preference despite its name: it describes whether a download
  # will finish, not the file it produces, and StallDetector covers dead torrents.
  @preference_keys [
    :preferred_video_codecs,
    :preferred_audio_codecs,
    :preferred_audio_channels,
    :preferred_resolutions,
    :preferred_sources,
    :hdr_formats,
    :min_ratio
  ]

  @doc "The `quality_standards` keys that are hard limits."
  @spec limit_keys() :: [atom()]
  def limit_keys, do: @limit_keys

  @doc "The `quality_standards` keys that only affect ranking."
  @spec preference_keys() :: [atom()]
  def preference_keys, do: @preference_keys

  @doc """
  Whether limits remove releases for this ranking pass. Reads
  `:apply_profile_limits` (default `true`) and never infers the answer from
  whether a profile is present: manual search passes a profile for scoring and
  still must not remove anything.
  """
  @spec enforced?(keyword()) :: boolean()
  def enforced?(opts), do: Keyword.get(opts, :apply_profile_limits, true)

  @doc """
  Removes every release that breaks a limit, logging why. Returns `results`
  unchanged when `enforced?/1` is false.
  """
  @spec reject([SearchResult.t()], keyword()) :: [SearchResult.t()]
  def reject(results, opts) do
    if enforced?(opts) do
      Enum.filter(results, fn result ->
        case violation(result, opts) do
          nil ->
            true

          reason ->
            Logger.info("[ReleaseRanker] Filtered out (#{reason}): #{result.title}")
            false
        end
      end)
    else
      results
    end
  end

  @doc """
  The first limit `result` breaks, as a `"<reason>: <detail>"` string, or nil.

  Ignores `:apply_profile_limits`, so manual search can still show the reason.
  """
  @spec violation(SearchResult.t(), keyword()) :: String.t() | nil
  def violation(%SearchResult{} = result, opts) do
    standards = standards(opts)

    source_limit(result, standards) || resolution_limit(result, standards) ||
      hdr_limit(result, standards) || size_limit(result, opts)
  end

  @doc """
  A season pack's result with its size divided by `episode_count`, so the pack
  is judged against per-episode bounds. A single episode, an unknown size, or a
  nil or single-episode count leaves the result unchanged.
  """
  @spec per_episode_sized(SearchResult.t(), pos_integer() | nil) :: SearchResult.t()
  def per_episode_sized(%SearchResult{size: size} = result, count)
      when is_integer(size) and is_integer(count) and count > 1 do
    if season_pack?(result), do: %{result | size: div(size, count)}, else: result
  end

  def per_episode_sized(result, _count), do: result

  defp standards(opts) do
    case Keyword.get(opts, :quality_profile) do
      %{quality_standards: standards} when is_map(standards) -> standards
      _ -> %{}
    end
  end

  # An unparseable source is no evidence either way, so it passes.
  defp source_limit(result, standards) do
    with [_ | _] = excluded <- Map.get(standards, :excluded_sources) || [],
         source when is_binary(source) <- result_source(result),
         true <- source in excluded do
      "excluded_source: #{source}"
    else
      _ -> nil
    end
  end

  defp result_source(%SearchResult{quality: %{source: source}}) when is_binary(source), do: source
  defp result_source(%SearchResult{title: title}) when is_binary(title), do: Sources.detect(title)
  defp result_source(_), do: nil

  # A release with no resolution token counts as
  # QualityParser.assumed_resolution/0, so an untagged SD rip cannot slip under
  # the floor by being unreadable. A bound outside the canonical vocabulary
  # means no bound.
  defp resolution_limit(%SearchResult{quality: quality}, standards) do
    order = QualityProfile.valid_resolutions()
    resolution = QualityParser.effective_resolution(quality)
    index = Enum.find_index(order, &(&1 == resolution))
    floor_index = bound_index(order, Map.get(standards, :min_resolution))
    ceiling_index = bound_index(order, Map.get(standards, :max_resolution))
    note = assumed_note(quality)

    cond do
      is_nil(index) ->
        nil

      floor_index && index < floor_index ->
        "resolution_below_minimum: #{resolution}#{note} < #{Enum.at(order, floor_index)}"

      ceiling_index && index > ceiling_index ->
        "resolution_above_maximum: #{resolution}#{note} > #{Enum.at(order, ceiling_index)}"

      true ->
        nil
    end
  end

  defp bound_index(order, bound) when is_binary(bound), do: Enum.find_index(order, &(&1 == bound))
  defp bound_index(_order, _bound), do: nil

  # Names the assumed resolution explicitly, so an operator reading Activity is
  # not left wondering why a `resolution: null` row was cut.
  defp assumed_note(quality) do
    if is_nil(quality) or is_nil(quality.resolution),
      do: " (assumed, no resolution in title)",
      else: ""
  end

  defp hdr_limit(%SearchResult{quality: quality}, standards) do
    if Map.get(standards, :require_hdr) == true and not hdr?(quality),
      do: "hdr_required: no HDR in title"
  end

  defp hdr?(%Quality{} = quality), do: Quality.hdr?(quality)
  defp hdr?(_quality), do: false

  # An unknown size (0 or nil) cannot be judged, so it passes. The upgrade
  # scorer re-checks the imported file.
  defp size_limit(%SearchResult{} = result, opts) do
    sized = per_episode_sized(result, Keyword.get(opts, :episode_count))

    with {min_mb, max_mb} <- size_range(opts),
         size when is_integer(size) and size > 0 <- sized.size do
      size_mb = size / @bytes_per_mb
      per_episode = if sized.size != result.size, do: " per episode", else: ""

      cond do
        is_number(min_mb) and size_mb < min_mb ->
          "size_below_minimum: #{round(size_mb)} MB#{per_episode} < #{min_mb} MB"

        is_number(max_mb) and size_mb > max_mb ->
          "size_above_maximum: #{round(size_mb)} MB#{per_episode} > #{max_mb} MB"

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  # RankingOptions.build/1 always puts the profile's range under :size_range,
  # so the fallback only matters to callers that pass a bare profile.
  defp size_range(opts) do
    case Keyword.fetch(opts, :size_range) do
      {:ok, range} ->
        range

      :error ->
        profile_size_range(
          Keyword.get(opts, :quality_profile),
          Keyword.get(opts, :media_type, :movie)
        )
    end
  end

  defp profile_size_range(%{quality_standards: _} = profile, media_type)
       when media_type in [:movie, :episode] do
    profile |> RankingOptions.extract_size_range(media_type) |> Keyword.get(:size_range)
  end

  defp profile_size_range(_profile, _media_type), do: nil

  defp season_pack?(%SearchResult{title: title}) do
    case ReleaseParser.parse(title) do
      %ParsedFileInfo{season: season, episodes: episodes} when is_integer(season) ->
        episodes in [nil, []]

      _ ->
        false
    end
  end
end
