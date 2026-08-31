defmodule Mydia.Indexers.SearchScorer do
  @moduledoc """
  Unified search result scoring module.

  This module provides a single source of truth for scoring search results,
  used by both manual UI searches and automatic background searches.

  ## Scoring Algorithm

  Combined Score = (quality_score * 0.6 + seeder_score + title_bonus) * zero_seeder_penalty

  Where:
  - quality_score: 0-100 (from QualityProfile.score_media_file/2 or fallback)
  - seeder_score: log10(seeders + 1) * 10 (max ~30 pts)
  - title_bonus: title_relevance_bonus / 2 (0-10 pts)
  - zero_seeder_penalty: 0.7 if seeders == 0, else 1.0

  ## Usage

      # Score a single result
      SearchScorer.score_result(result, quality_profile: profile, media_type: :movie, search_query: "...")

      # Get full breakdown
      SearchScorer.score_result_with_breakdown(result, quality_profile: profile, media_type: :movie, search_query: "...")
  """

  alias Mydia.Indexers.QualityParser
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.Hdr
  alias Mydia.Settings.QualityProfile

  @type score_opts :: [
          quality_profile: QualityProfile.t() | nil,
          media_type: :movie | :episode,
          search_query: String.t() | nil
        ]

  @type score_breakdown :: %{
          score: float(),
          breakdown: map(),
          violations: [String.t()],
          detected: map()
        }

  @doc """
  Calculate the combined score for a search result.

  Returns a float score that can be used for sorting results.

  ## Options

  - `:quality_profile` - The quality profile to use for scoring (optional)
  - `:media_type` - Either `:movie` or `:episode` (default: `:movie`)
  - `:search_query` - The original search query for title relevance scoring (optional)
  """
  @spec score_result(SearchResult.t(), score_opts()) :: float()
  def score_result(%SearchResult{} = result, opts \\ []) do
    breakdown = score_result_with_breakdown(result, opts)
    breakdown.score
  end

  @doc """
  Calculate the combined score with full breakdown for a search result.

  Returns a map with:
  - `:score` - Overall combined score
  - `:breakdown` - Map with individual component scores
  - `:violations` - List of constraint violations (if any)
  - `:detected` - Map of detected quality attributes from the result
  """
  @spec score_result_with_breakdown(SearchResult.t(), score_opts()) :: score_breakdown()
  def score_result_with_breakdown(%SearchResult{} = result, opts \\ []) do
    quality_profile = Keyword.get(opts, :quality_profile)
    media_type = Keyword.get(opts, :media_type, :movie)
    search_query = Keyword.get(opts, :search_query)

    # Calculate individual component scores
    {quality_score, quality_breakdown, violations} =
      score_quality(result, quality_profile, media_type)

    title_bonus = score_title_match(result.title, search_query)

    # Branch on download protocol so NZB results aren't scored on torrent
    # seeders (which are always nil for Usenet).
    {availability_score, availability_penalty, availability_violations} =
      score_availability(result)

    # Combined score: quality (60%) + availability (~30%) + title (10%)
    combined_score =
      (quality_score * 0.6 + availability_score + title_bonus) * availability_penalty

    # Build full breakdown. Keep the historical key name :seeder_score for
    # downstream compatibility; for NZB it represents the equivalent
    # availability score derived from completion + grabs.
    breakdown =
      quality_breakdown
      |> Map.put(:quality_score, Float.round(quality_score, 1))
      |> Map.put(:seeder_score, Float.round(availability_score, 1))
      |> Map.put(:title_bonus, Float.round(title_bonus, 1))
      |> Map.put(:zero_seeder_penalty, availability_penalty)

    violations = violations ++ availability_violations

    %{
      score: Float.round(combined_score, 1),
      breakdown: breakdown,
      violations: violations,
      detected: extract_detected_quality(result)
    }
  end

  # Returns {score, penalty_multiplier, violations} for the availability
  # dimension. Torrents use seeders; NZB uses completion + grabs.
  @spec score_availability(SearchResult.t()) :: {float(), float(), [String.t()]}
  defp score_availability(%SearchResult{download_protocol: :nzb} = result) do
    score = score_nzb_availability(result.nzb_completion, result.nzb_grabs)

    # NZB results don't suffer the "dead torrent" penalty: completion is the
    # quality signal, and missing completion is normalized to 1.0 (we trust
    # the indexer rather than penalizing it).
    {score, 1.0, []}
  end

  defp score_availability(%SearchResult{seeders: nil}) do
    # Unknown protocol with no seeders info - treat as no availability data.
    {0.0, 0.7, ["No seeders (30% penalty applied)"]}
  end

  defp score_availability(%SearchResult{seeders: seeders}) do
    score = score_seeders(seeders)
    penalty = if seeders == 0, do: 0.7, else: 1.0
    violations = if seeders == 0, do: ["No seeders (30% penalty applied)"], else: []
    {score, penalty, violations}
  end

  # NZB availability blends completion (most important - articles present)
  # with grabs (a tiebreaker hinting at general health). Defaults completion
  # to 1.0 when unknown to avoid penalizing indexers that don't report it.
  defp score_nzb_availability(completion, grabs) do
    completion =
      if is_float(completion) or is_integer(completion), do: completion * 1.0, else: 1.0

    # Map completion 0.0..1.0 → 0..30 to mirror torrent seeder scale.
    completion_score = completion * 30.0
    # Grabs tiebreaker on a log10 scale, capped well below completion.
    grabs_score = score_grabs(grabs)
    completion_score + grabs_score
  end

  defp score_grabs(nil), do: 0.0
  defp score_grabs(grabs) when grabs <= 0, do: 0.0
  defp score_grabs(grabs), do: min(5.0, :math.log10(grabs + 1) * 2)

  @doc """
  Calculate quality score for a search result.

  If a quality profile is provided, uses QualityProfile.score_media_file/2.
  Otherwise, returns a fallback score based on seeders.

  Returns {score, breakdown, violations} tuple.
  """
  @spec score_quality(SearchResult.t(), QualityProfile.t() | nil, :movie | :episode) ::
          {float(), map(), [String.t()]}
  def score_quality(%SearchResult{} = result, nil, _media_type) do
    # No profile set - use availability as the primary quality indicator.
    # Without a quality profile, users haven't expressed quality preferences,
    # so we prioritize availability (seeders for torrents, completion for NZB).
    quality_score =
      case result do
        %SearchResult{download_protocol: :nzb} ->
          # NZB: 100 * completion. Default completion to 1.0 when unknown.
          completion = result.nzb_completion || 1.0
          min(completion * 100.0, 100.0)

        %SearchResult{seeders: nil} ->
          0.0

        %SearchResult{seeders: seeders} ->
          min(seeders * 1.0, 100.0)
      end

    {quality_score, %{raw_quality_score: quality_score}, []}
  end

  def score_quality(%SearchResult{} = result, %QualityProfile{} = profile, media_type) do
    # Convert search result to media_attrs format for scoring
    media_attrs = search_result_to_media_attrs(result, media_type)

    score_result = QualityProfile.score_media_file(profile, media_attrs)

    {score_result.score, score_result.breakdown, score_result.violations}
  end

  @doc """
  Calculate seeder score using logarithmic scale.

  0 seeders = 0, 10 seeders = 10, 100 seeders = 20, 1000 seeders = 30

  Returns a score in the range 0-30.
  """
  @spec score_seeders(non_neg_integer()) :: float()
  def score_seeders(seeders) when seeders <= 0, do: 0.0

  def score_seeders(seeders) do
    :math.log10(seeders + 1) * 10
  end

  @doc """
  Calculate title relevance bonus.

  Scores how well the result title matches the search query.
  Returns a score in the range 0-10.
  """
  @spec score_title_match(String.t(), String.t() | nil) :: float()
  def score_title_match(_title, nil), do: 0.0
  def score_title_match(_title, ""), do: 0.0

  def score_title_match(title, search_query) do
    # Calculate raw title relevance bonus (0-20 scale) and divide by 2 for 0-10 range
    raw_bonus = calculate_title_relevance_bonus(title, search_query)
    raw_bonus / 2
  end

  # Private functions

  # Calculate title relevance bonus (0-20 points)
  # Penalizes results with extra unrelated words in the title
  defp calculate_title_relevance_bonus(title, search_query) do
    query_words = normalize_to_words(search_query)
    title_words = normalize_to_words(title)

    if query_words == [] do
      0.0
    else
      # Count matched words
      matched_words =
        Enum.count(query_words, fn query_word ->
          Enum.any?(title_words, fn title_word ->
            title_word == query_word or
              String.starts_with?(title_word, query_word) or
              String.starts_with?(query_word, title_word)
          end)
        end)

      match_ratio = matched_words / length(query_words)

      # Check if title starts with the query (significant word match)
      significant_query = filter_common_words(query_words)
      significant_title = filter_common_words(title_words)

      starts_with_bonus =
        case {significant_query, significant_title} do
          {[first_q | _], [first_t | _]} when first_q == first_t -> 5.0
          _ -> 0.0
        end

      # Penalty for extra unrelated words (not in query, not quality/episode markers)
      extra_words =
        title_words
        |> Enum.reject(fn word ->
          Enum.member?(query_words, word) or quality_or_episode_word?(word)
        end)
        |> length()

      # More extra words = bigger penalty (max -10 points)
      extra_penalty = min(extra_words * 2, 10)

      # Base bonus (up to 15 points based on match ratio) + starts_with - penalty
      base_bonus = match_ratio * 15

      max(0.0, base_bonus + starts_with_bonus - extra_penalty)
    end
  end

  defp normalize_to_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[._\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(&1 != ""))
  end

  defp filter_common_words(words) do
    common = ~w(the a an of and or in on at to for)
    Enum.reject(words, &Enum.member?(common, &1))
  end

  defp quality_or_episode_word?(word) do
    quality_words = ~w(
      2160p 1080p 720p 480p 4k uhd hd sd
      x264 x265 h264 h265 hevc avc av1
      bluray bdrip brrip webrip webdl web hdtv hdrip dvdrip
      remux proper repack
      dts atmos truehd dolby aac ac3 flac ddp ddp5
      hdr hdr10 dolbyvision dv
      nf amzn atvp
    )

    episode_pattern = ~r/^(s\d+e?\d*|e\d+|\d{3,4}p)$/i
    year_pattern = ~r/^(19|20)\d{2}$/

    Enum.member?(quality_words, word) or
      String.match?(word, episode_pattern) or
      String.match?(word, year_pattern)
  end

  # Convert SearchResult to the media_attrs format expected by QualityProfile.score_media_file/2
  #
  # `:resolution` goes through QualityParser.effective_resolution/1, so an
  # untagged release is measured as 360p rather than as "unknown". A nil here
  # scored a neutral 50 and produced no range violation, ranking it above an
  # honestly-labelled out-of-range release at 25. The assumption belongs at
  # this seam and not inside score_media_file/2, which Mydia.Upgrades.Comparator
  # also calls for real files, where a nil resolution means "not analyzed yet".
  defp search_result_to_media_attrs(%SearchResult{quality: nil} = result, media_type) do
    # No quality info available
    file_size_mb = if result.size, do: result.size / (1024 * 1024), else: nil

    %{
      resolution: QualityParser.effective_resolution(nil),
      source: nil,
      video_codec: nil,
      audio_codec: nil,
      file_size_mb: file_size_mb,
      media_type: media_type
    }
  end

  defp search_result_to_media_attrs(%SearchResult{quality: quality} = result, media_type) do
    # Map codec names to the format expected by quality profiles
    video_codec = normalize_codec(quality.codec)
    audio_codec = normalize_audio_codec(quality.audio)

    # Convert size from bytes to MB
    file_size_mb = if result.size, do: result.size / (1024 * 1024), else: nil

    base_attrs = %{
      resolution: QualityParser.effective_resolution(quality),
      source: quality.source,
      video_codec: video_codec,
      audio_codec: audio_codec,
      audio_channels: extract_audio_channels(quality.audio),
      file_size_mb: file_size_mb,
      media_type: media_type
    }

    # HDR tokens by specificity, e.g. ["dolby_vision", "hdr10"] for a DV 8.1
    # release. Omitted entirely when the release carries no HDR signal, which
    # is what score_hdr_format/2's SDR fallback clause expects.
    tokens =
      Hdr.profile_tokens(%Hdr{
        base: quality.hdr_format,
        dv_profile: if(quality.dolby_vision, do: 8)
      })

    if tokens == [], do: base_attrs, else: Map.put(base_attrs, :hdr_tokens, tokens)
  end

  # Extract detected quality attributes from search result for display
  defp extract_detected_quality(%SearchResult{quality: nil}), do: %{}

  defp extract_detected_quality(%SearchResult{quality: quality} = result) do
    %{
      resolution: quality.resolution,
      source: quality.source,
      video_codec: normalize_codec(quality.codec),
      audio_codec: normalize_audio_codec(quality.audio),
      hdr:
        Hdr.display(%Hdr{
          base: quality.hdr_format,
          dv_profile: if(quality.dolby_vision, do: 8)
        }),
      size_mb: if(result.size, do: Float.round(result.size / (1024 * 1024), 1), else: nil)
    }
  end

  # Derive an audio channel layout (e.g. "5.1", "7.1", "7.1.2", "2.0") from the
  # parsed audio string so quality_standards.preferred_audio_channels has a real
  # effect on search ranking. Returns nil when no channel notation is present.
  defp extract_audio_channels(nil), do: nil

  defp extract_audio_channels(audio) when is_binary(audio) do
    case Regex.run(~r/(?<!\d)(\d\.\d(?:\.\d)?)(?!\d)/, audio) do
      [_, channels] -> channels
      _ -> nil
    end
  end

  # Normalize video codec names to match quality profile format
  defp normalize_codec(nil), do: nil

  defp normalize_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> case do
      "x264" -> "h264"
      "x265" -> "h265"
      "h.264" -> "h264"
      "h.265" -> "h265"
      other -> other
    end
  end

  # Normalize audio codec names to match quality profile format
  defp normalize_audio_codec(nil), do: nil

  defp normalize_audio_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> case do
      # TrueHD Atmos is the highest tier - map to "atmos"
      "truehd atmos" -> "atmos"
      "atmos" -> "atmos"
      "dolby atmos" -> "atmos"
      # TrueHD without Atmos
      "truehd" -> "truehd"
      "dolby truehd" -> "truehd"
      # DTS variants
      "dts:x" -> "dts-hd"
      "dts-hd ma" -> "dts-hd"
      "dts-hd" -> "dts-hd"
      # Dolby Digital variants
      "dd+" -> "eac3"
      "ddp" -> "eac3"
      "dd" -> "ac3"
      other -> other
    end
  end
end
