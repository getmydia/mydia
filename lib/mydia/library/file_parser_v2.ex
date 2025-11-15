defmodule Mydia.Library.FileParser.V2 do
  @moduledoc """
  Sequential pattern-based media file parser (Version 2).

  This parser uses a PTN (Parse Torrent Name) inspired approach where:
  1. Each pattern is applied to the filename sequentially
  2. Matched portions are extracted and removed from the text
  3. What remains after all patterns is the title

  ## Algorithm

  ```
  filename = "Movie.Title.2020.1080p.BluRay.x264-GROUP.mkv"

  Apply patterns sequentially:
    - Year pattern: Match "2020" → Remove → year=2020
    - Resolution: Match "1080p" → Remove → resolution=1080p
    - Source: Match "BluRay" → Remove → source=BluRay
    - Codec: Match "x264" → Remove → codec=x.264
    - Release group: Match "-GROUP" → Remove → group=GROUP

  Remaining text: "Movie Title" ✓
  ```

  ## Benefits

  - **Robust**: Patterns handle variations automatically
  - **Maintainable**: Add pattern once instead of every variant
  - **Scalable**: Gracefully handles edge cases
  - **Industry Standard**: Aligns with PTN/GuessIt approach

  ## References

  - PTN: https://github.com/divijbindlish/parse-torrent-name
  - GuessIt: https://github.com/guessit-io/guessit
  - Analysis: docs/file_parser_analysis.md
  """

  require Logger

  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  @type media_type :: :movie | :tv_show | :unknown

  # Keep backward-compatible type alias
  @type parse_result :: ParsedFileInfo.t()

  # Regex patterns from Phase 1
  # Order matters: match longer patterns first (DTS-HD before DTS, AAC-LC before AAC, DDP before DD)
  @audio_pattern ~r/
    \b
    (?:
      DTS-HD(?:[\s.]MA)?                  # DTS-HD.MA, DTS-HD MA, DTS-HD (must be before DTS)
      |DTS-X                               # DTS-X (must be before DTS)
      |DTS                                 # Plain DTS
      |DDP(?:\d+[\s.]?\d*)?                # DDP, DDP5.1, DDP51, DDP7.1 (must be before DD)
      |DD(?:\d+[\s.]?\d*)?                 # DD, DD5.1, DD51, DD7.1
      |EAC3(?:\d+[\s.]?\d*)?               # E-AC3 (same as DDP)
      |TrueHD(?:[\s.]\d+[\s.]?\d*)?        # TrueHD, TrueHD 7.1, TrueHD 7 1
      |Atmos
      |AAC-LC(?:[\s.]\d+[\s.]?\d*)?        # AAC-LC (must be before AAC)
      |AAC(?:[\s.]\d+[\s.]?\d*)?           # AAC, AAC 2.0
      |AC3
      |OPUS(?:\d+[\s.]?\d*)?               # OPUS, OPUS2.0
    )
    \b
  /xi

  @codec_pattern ~r/
    \b
    (?:
      [hxHX][\s.]?26[45]                  # x264, x.264, x 264, h264, h.264, h 264, x265, h265, etc.
      |HEVC|AVC                            # HEVC, AVC
      |XviD|DivX                           # Legacy codecs
      |VP9|AV1                             # Modern codecs
      |NVENC                               # Hardware encoder
    )
    \b
  /xi

  @resolution_pattern ~r/\b(?:\d{3,4}[pP]|4K|8K|UHD)\b/i

  # Source pattern - order matters: match longer patterns first (WEB-DL before WEB)
  @source_pattern ~r/
    \b
    (?:
      REMUX
      |BluRay|BDRip|BRRip
      |WEB-DL                            # WEB-DL (must be before WEB)
      |WEBRip                            # WEBRip (must be before WEB)
      |WEB                               # Plain WEB
      |HDTV
      |DVDRip                            # DVDRip (must be before DVD)
      |DVD                               # Plain DVD
    )
    \b
  /xi

  @hdr_pattern ~r/(?:\bHDR10\+|\b(?:DolbyVision|DoVi|HDR10|HDR)\b)/i

  # Additional noise patterns
  @bit_depth_pattern ~r/\b(8|10|12)[\s-]?bits?\b/i
  @encoder_pattern ~r/[-_. ](NVENC|QSV|AMF|VCE|VideoToolbox)\b/i
  @bracket_contents_pattern ~r/\[(HDR|HDR10|HDR10\+|DolbyVision|DoVi|10bit|8bit|x265|x264|HEVC|AVC|2160p|1080p|720p)[^\]]*\]/i
  @extra_noise_pattern ~r/\b(PROPER|REPACK|INTERNAL|LIMITED|UNRATED|DIRECTORS?\.CUT|EXTENDED|THEATRICAL|AMZN|NF|HYBRID)\b/i
  @audio_channels_pattern ~r/\b[257]\s+1\b/i
  @vmaf_pattern ~r/\bVMAF\d+(?:\.\d+)?\b/i

  # Year pattern - prioritize parenthesized/bracketed years
  @year_pattern_primary ~r/[\(\[](19\d{2}|20\d{2})[\)\]]/
  @year_pattern_secondary ~r/[\s._-](19\d{2}|20\d{2})(?:[\s._-]|$)/

  # Release group pattern - hyphen, dot, or space prefix with optional site tag in brackets
  @release_group_pattern ~r/[-.\s]([A-Z0-9]+)(?:\[[^\]]+\])?$/i

  # TV show patterns - defined as function to avoid module attribute issues
  defp tv_patterns do
    [
      # S01E01 or s01e01, with optional multi-episode S01E01-E03 or S01E01E03
      ~r/[. _-]S(\d{1,2})E(\d{1,2})(?:-?E(\d{1,2}))?/i,
      # 1x01
      ~r/[. _-](\d{1,2})x(\d{1,2})/i,
      # Season 1 Episode 1 (verbose)
      ~r/Season[. _-](\d{1,2})[. _-]Episode[. _-](\d{1,2})/i
    ]
  end

  # Pattern definitions are created in extraction_patterns/0 function
  # to avoid module attribute injection issues with function references

  @doc """
  Parses a file name or path and extracts media metadata using sequential pattern extraction.

  ## Options

  - `:standardize` - When `true`, converts codec/source variations to canonical forms (default: `false`)

  ## Examples

      iex> FileParser.V2.parse("Movie.Title.2020.1080p.BluRay.x264-GROUP.mkv")
      %{
        type: :movie,
        title: "Movie Title",
        year: 2020,
        quality: %{resolution: "1080p", source: "BluRay", codec: "x.264"},
        release_group: "GROUP",
        confidence: 0.95
      }

      iex> FileParser.V2.parse("Show.Name.S01E05.720p.WEB.mkv", standardize: true)
      %{
        type: :tv_show,
        title: "Show Name",
        season: 1,
        episodes: [5],
        quality: %{resolution: "720p", source: "WEB"},
        confidence: 0.9
      }
  """
  @spec parse(String.t(), keyword()) :: parse_result()
  def parse(filename, opts \\ []) when is_binary(filename) do
    # Normalize filename (remove extension, convert dots/underscores to spaces)
    normalized = normalize_filename(filename)

    # Apply sequential extraction
    {metadata, remaining_text} = extract_all_patterns(normalized)

    # Extract title from remaining text
    title = clean_title(remaining_text)

    # Build result
    result = build_result(metadata, title, filename, opts)

    Logger.debug("FileParser.V2 parsed file",
      original: filename,
      type: result.type,
      title: result.title,
      year: result.year,
      season: result.season,
      episodes: result.episodes,
      confidence: result.confidence
    )

    result
  end

  ## Sequential Extraction

  # Define extraction patterns as a function to avoid module attribute issues
  defp extraction_patterns do
    [
      # TV show pattern - must be first to identify TV shows before other patterns
      %{
        name: :tv_show,
        type: :tv_identifier,
        regex: :tv_patterns,
        handler: &extract_tv_info/3
      },
      # Year (primary) - parenthesized/bracketed years first (highest priority)
      %{
        name: :year,
        type: :metadata,
        regex: @year_pattern_primary,
        handler: &extract_year/3
      },
      # Quality markers - extract before release group to avoid partial matches
      %{
        name: :resolution,
        type: :quality,
        regex: @resolution_pattern,
        handler: &extract_resolution/3
      },
      %{
        name: :source,
        type: :quality,
        regex: @source_pattern,
        handler: &extract_source/3
      },
      %{
        name: :codec,
        type: :quality,
        regex: @codec_pattern,
        handler: &extract_codec/3
      },
      %{
        name: :hdr_format,
        type: :quality,
        regex: @hdr_pattern,
        handler: &extract_hdr/3
      },
      %{
        name: :audio,
        type: :quality,
        regex: @audio_pattern,
        handler: &extract_audio/3
      },
      # Noise patterns - remove but don't extract
      %{
        name: :bit_depth,
        type: :noise,
        regex: @bit_depth_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :encoder,
        type: :noise,
        regex: @encoder_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :audio_channels,
        type: :noise,
        regex: @audio_channels_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :vmaf,
        type: :noise,
        regex: @vmaf_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :bracket_contents,
        type: :noise,
        regex: @bracket_contents_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :extra_noise,
        type: :noise,
        regex: @extra_noise_pattern,
        handler: &extract_and_discard/3
      },
      # Year (secondary) - standalone years (only if no year extracted yet)
      %{
        name: :year_secondary,
        type: :metadata_conditional,
        regex: @year_pattern_secondary,
        handler: &extract_year_conditional/3
      },
      # Release group - extract LAST to avoid conflicting with quality markers (DTS-HD, WEB-DL, AAC-LC)
      %{
        name: :release_group,
        type: :metadata,
        regex: @release_group_pattern,
        handler: &extract_release_group/3
      }
    ]
  end

  defp extract_all_patterns(text) do
    # Reduce over all patterns, extracting and removing matches sequentially
    Enum.reduce(extraction_patterns(), {%{}, text}, fn pattern, {metadata, remaining_text} ->
      extract_pattern(pattern, metadata, remaining_text)
    end)
  end

  defp extract_pattern(%{regex: :tv_patterns}, metadata, text) do
    # Special case: TV patterns use a list of regexes
    case match_tv_patterns(text) do
      {:ok, tv_metadata, match_start, match_length} ->
        # Remove the matched TV pattern from text and everything after it until a quality marker
        before = String.slice(text, 0, match_start)
        after_match = String.slice(text, match_start + match_length, String.length(text))

        # Discard text between episode marker and first quality marker to remove episode titles
        after_match_cleaned = discard_until_quality_marker(after_match)

        new_text = before <> " " <> after_match_cleaned

        # Merge TV metadata into main metadata
        {Map.merge(metadata, tv_metadata), new_text}

      :error ->
        {metadata, text}
    end
  end

  defp extract_pattern(pattern, metadata, text) do
    # Skip conditional patterns if the condition is not met
    if pattern.type == :metadata_conditional do
      # For conditional year extraction, only proceed if no year was extracted yet
      if Map.has_key?(metadata, :year) do
        {metadata, text}
      else
        do_extract_pattern(pattern, metadata, text, :year)
      end
    else
      do_extract_pattern(pattern, metadata, text, nil)
    end
  end

  defp do_extract_pattern(pattern, metadata, text, target_key) do
    case Regex.run(pattern.regex, text, return: :index) do
      nil ->
        # No match, continue with same metadata and text
        {metadata, text}

      [{start, length} | _captures] ->
        # Extract the matched portion
        match = String.slice(text, start, length)

        # Call the handler to extract value
        value = pattern.handler.(match, text, metadata)

        # Remove matched portion from text (replace with space to preserve word boundaries)
        new_text =
          String.slice(text, 0, start) <>
            " " <> String.slice(text, start + length, String.length(text))

        # Update metadata if value is not nil (noise patterns return nil)
        new_metadata =
          if value != nil do
            final_key = target_key || pattern.name

            case pattern.type do
              :quality ->
                # Update quality map (will be converted to struct in build_result)
                quality = Map.get(metadata, :quality, %{})
                Map.put(metadata, :quality, Map.put(quality, pattern.name, value))

              :metadata_conditional ->
                # Add to metadata with target key
                Map.put(metadata, final_key, value)

              _ ->
                # Add to metadata directly
                Map.put(metadata, pattern.name, value)
            end
          else
            metadata
          end

        {new_metadata, new_text}
    end
  end

  ## Pattern Handlers

  # TV show pattern matcher
  defp match_tv_patterns(text) do
    Enum.reduce_while(tv_patterns(), :error, fn pattern, _acc ->
      case Regex.run(pattern, text, return: :index) do
        nil ->
          {:cont, :error}

        [{match_start, match_length} | captures] ->
          # Extract season and episode numbers from captures
          {season, episodes} = parse_tv_captures(text, captures)

          tv_metadata = %{
            type: :tv_show,
            season: season,
            episodes: episodes
          }

          {:halt, {:ok, tv_metadata, match_start, match_length}}
      end
    end)
  end

  defp parse_tv_captures(text, captures) do
    numbers =
      captures
      |> Enum.reject(&(&1 == {-1, 0}))
      |> Enum.map(fn {start, length} ->
        text
        |> String.slice(start, length)
        |> String.to_integer()
      end)

    case numbers do
      [season, episode] ->
        {season, [episode]}

      [season, episode1, episode2] ->
        # Multi-episode (e.g., S01E01-E03)
        {season, Enum.to_list(episode1..episode2)}

      _ ->
        {nil, []}
    end
  end

  # Discard text until we hit a quality marker to remove episode titles, but preserve years
  defp discard_until_quality_marker(text) do
    # First, check if there's a year in parentheses/brackets in the text
    year_match =
      case Regex.run(@year_pattern_primary, text, return: :index) do
        [{start, length} | _] -> {start, length}
        nil -> nil
      end

    # Look for the first occurrence of any quality marker pattern
    quality_patterns = [
      @resolution_pattern,
      @source_pattern,
      @codec_pattern,
      @hdr_pattern,
      @audio_pattern,
      @bit_depth_pattern,
      @release_group_pattern
    ]

    # Find the earliest match position among all quality patterns
    earliest_match =
      quality_patterns
      |> Enum.map(fn pattern ->
        case Regex.run(pattern, text, return: :index) do
          [{start, _length} | _] -> start
          nil -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    case {year_match, earliest_match} do
      {nil, nil} ->
        # No year, no quality marker - discard everything
        ""

      {{year_start, year_length}, nil} ->
        # Year found but no quality marker - preserve only the year
        String.slice(text, year_start, year_length)

      {nil, position} ->
        # No year, but quality marker found - keep from quality marker onward
        String.slice(text, position, String.length(text))

      {{year_start, year_length}, position} ->
        # Both year and quality marker found - preserve year and everything from quality marker
        year_text = String.slice(text, year_start, year_length)
        quality_text = String.slice(text, position, String.length(text))
        year_text <> " " <> quality_text
    end
  end

  def extract_tv_info(_match, _text, _metadata) do
    # TV info is handled specially in match_tv_patterns
    nil
  end

  def extract_year(match, _text, _metadata) do
    # Extract year from match (can be in parentheses, brackets, dots, or standalone)
    case Regex.run(~r/(19\d{2}|20\d{2})/, match) do
      [_, year_str] -> String.to_integer(year_str)
      [year_str] -> String.to_integer(year_str)
      _ -> nil
    end
  end

  def extract_year_conditional(match, _text, _metadata) do
    # Same as extract_year, but only called if no year was extracted yet
    extract_year(match, nil, nil)
  end

  def extract_release_group(match, _text, _metadata) do
    # Extract group name from hyphen-prefixed pattern (with optional site tag)
    case Regex.run(@release_group_pattern, match) do
      [_, group] -> group
      _ -> nil
    end
  end

  def extract_resolution(match, _text, _metadata) do
    # Normalize resolution case (1080P → 1080p)
    cond do
      String.match?(match, ~r/^\d+[pP]$/) ->
        String.replace(match, ~r/[pP]$/, "p")

      true ->
        match
    end
  end

  def extract_source(match, _text, _metadata) do
    match
  end

  def extract_codec(match, _text, _metadata) do
    # Normalize codec (x 264 → x.264, h 264 → h.264)
    if String.match?(match, ~r/^[hxHX]\s26[45]$/i) do
      String.replace(match, " ", ".")
    else
      match
    end
  end

  def extract_hdr(match, _text, _metadata) do
    # Normalize HDR10+ correctly
    cleaned_match = String.trim(match)

    if String.contains?(cleaned_match, "HDR10+") ||
         String.contains?(cleaned_match, "HDR10 ") do
      "HDR10+"
    else
      cleaned_match
    end
  end

  def extract_audio(match, _text, _metadata) do
    # Normalize audio codec
    normalized =
      if String.match?(match, ~r/\d\s\d/) do
        # Restore dots in channel specs (5 1 → 5.1)
        String.replace(match, ~r/(\d)\s(\d)/, "\\1.\\2")
      else
        match
      end

    # Normalize DTS-HD MA → DTS-HD.MA
    if String.match?(normalized, ~r/DTS-HD\sMA/i) do
      String.replace(normalized, ~r/(DTS-HD)\s(MA)/i, "\\1.\\2")
    else
      normalized
    end
  end

  def extract_and_discard(_match, _text, _metadata) do
    # Noise patterns are removed but not extracted
    nil
  end

  ## Result Building

  defp build_result(metadata, title, original_filename, opts) do
    # Extract fields with defaults (no Map.get - direct access with defaults)
    type = metadata[:type] || :unknown
    year = metadata[:year]
    season = metadata[:season]
    episodes = metadata[:episodes]
    quality_map = metadata[:quality] || %{}
    release_group = metadata[:release_group]

    # Convert quality map to struct
    quality = Quality.new(quality_map)

    # Determine media type if not already set
    type =
      cond do
        type == :tv_show -> :tv_show
        season != nil || episodes != nil -> :tv_show
        true -> infer_media_type(title, year, quality)
      end

    # Calculate confidence
    confidence =
      case type do
        :tv_show -> calculate_tv_confidence(title, season, episodes, quality)
        :movie -> calculate_movie_confidence(title, year, quality)
        :unknown -> 0.0
      end

    # Apply standardization if requested
    quality =
      if Keyword.get(opts, :standardize, false) do
        standardize_quality(quality)
      else
        quality
      end

    # Return a struct instead of a plain map
    %ParsedFileInfo{
      type: type,
      title: title,
      year: year,
      season: season,
      episodes: episodes,
      quality: quality,
      release_group: release_group,
      confidence: confidence,
      original_filename: original_filename
    }
  end

  defp infer_media_type(title, year, quality) do
    # Require at least some meaningful attributes to classify as movie
    has_year = year != nil
    has_quality = !Quality.empty?(quality) && (quality.resolution != nil || quality.source != nil)
    has_good_title = title != nil && String.length(title) > 3

    cond do
      # Require at least year OR quality to classify as movie
      has_year || has_quality -> :movie
      # Files with no metadata but a title should be unknown (too ambiguous)
      has_good_title -> :unknown
      true -> :unknown
    end
  end

  ## Helper Functions

  defp normalize_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[_.]/, " ")
    |> String.trim()
  end

  defp clean_title(text) do
    # Known quality markers that might slip through (case-insensitive)
    quality_markers =
      ~w(uhd hdr hdr10 hdr10+ dolbyvision dovi remux atmos dts dd ddp eac3 truehd aac ac3 hevc avc xvid divx vp9 av1 nvenc web bluray bdrip brrip webrip webdl hdtv dvd dvdrip proper repack internal limited unrated extended theatrical amzn hybrid)

    text
    # Remove empty brackets/parentheses that remain after extraction
    |> String.replace(~r/[[(]\s*[])]/, " ")
    # Collapse multiple spaces
    |> String.replace(~r/\s+/, " ")
    # Remove multiple dashes/underscores
    |> String.replace(~r/[-_]{2,}/, " ")
    # Remove leading/trailing separators
    |> String.replace(~r/^[-_\s]+|[-_\s]+$/, "")
    |> String.trim()
    # Split into words and clean up
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == "" || &1 == "-" || &1 == "_" || &1 == "+"))
    # Filter out quality markers (case-insensitive) but preserve numbers that are part of titles
    |> Enum.reject(fn word ->
      String.downcase(word) in quality_markers
    end)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp calculate_movie_confidence(title, year, quality) do
    has_year = year != nil
    has_quality = !Quality.empty?(quality) && (quality.resolution != nil || quality.source != nil)
    has_good_title = title != nil && String.length(title) > 3

    base_confidence =
      cond do
        !has_good_title && !has_year && !has_quality -> 0.0
        !has_year && !has_quality -> 0.2
        true -> 0.5
      end

    confidence =
      base_confidence
      |> add_confidence(has_good_title, 0.2)
      |> add_confidence(year != nil, 0.15)
      |> add_confidence(quality.resolution != nil, 0.1)
      |> add_confidence(quality.source != nil, 0.05)

    min(confidence, 1.0)
  end

  defp calculate_tv_confidence(title, season, episodes, quality) do
    base_confidence = 0.6

    confidence =
      base_confidence
      |> add_confidence(title != nil && String.length(title) > 0, 0.15)
      |> add_confidence(season != nil, 0.1)
      |> add_confidence(episodes != nil && length(episodes) > 0, 0.1)
      |> add_confidence(quality.resolution != nil, 0.05)

    min(confidence, 1.0)
  end

  defp add_confidence(current, true, amount), do: current + amount
  defp add_confidence(current, false, _amount), do: current

  ## Standardization Layer (Phase 3)

  @doc """
  Standardizes quality metadata to canonical forms.

  ## Examples

      iex> standardize_quality(%{audio: "DDP5.1", codec: "x264"})
      %{audio: "Dolby Digital Plus 5.1", codec: "H.264/AVC"}
  """
  defp standardize_quality(%Quality{} = quality) do
    %Quality{
      audio: standardize_audio(quality.audio),
      codec: standardize_codec(quality.codec),
      source: standardize_source(quality.source),
      resolution: standardize_resolution(quality.resolution),
      hdr_format: standardize_hdr(quality.hdr_format)
    }
  end

  # Audio Codec Standardization
  defp standardize_audio(nil), do: nil

  defp standardize_audio(audio) do
    normalized = String.downcase(audio)

    cond do
      # Dolby Digital Plus (E-AC3) - must check EAC3 and AC3 separately from DDP/DD to avoid matching the "3"
      String.match?(normalized, ~r/^eac3$/i) ->
        "Dolby Digital Plus"

      Regex.match?(~r/^ddp(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(audio, "Dolby Digital Plus")

      # Dolby Digital (AC3) - must check AC3 separately from DD to avoid matching the "3"
      String.match?(normalized, ~r/^ac3$/i) ->
        "Dolby Digital"

      Regex.match?(~r/^dd(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(audio, "Dolby Digital")

      # DTS variants
      String.contains?(normalized, "dts-hd") && String.contains?(normalized, "ma") ->
        "DTS-HD Master Audio"

      String.contains?(normalized, "dts-hd") ->
        "DTS-HD High Resolution Audio"

      String.match?(normalized, ~r/^dts-x$/i) ->
        "DTS:X"

      String.match?(normalized, ~r/^dts$/i) ->
        "DTS"

      # Dolby TrueHD
      String.contains?(normalized, "truehd") ->
        extract_channels(audio, "Dolby TrueHD")

      # Dolby Atmos
      String.match?(normalized, ~r/^atmos$/i) ->
        "Dolby Atmos"

      # AAC variants
      String.match?(normalized, ~r/^aac-lc/i) ->
        "AAC-LC"

      String.match?(normalized, ~r/^aac/i) ->
        extract_channels(audio, "AAC")

      # Unknown - return as-is
      true ->
        audio
    end
  end

  defp extract_channels(audio, base_name) do
    case Regex.run(~r/(\d+\.?\d*)/, audio) do
      [_, channels] -> "#{base_name} #{channels}"
      _ -> base_name
    end
  end

  # Video Codec Standardization
  defp standardize_codec(nil), do: nil

  defp standardize_codec(codec) do
    normalized = String.downcase(codec)

    cond do
      # H.265/HEVC
      Regex.match?(~r/^[hx][\s.]?265$/i, normalized) || String.match?(normalized, ~r/^hevc$/i) ->
        "H.265/HEVC"

      # H.264/AVC
      Regex.match?(~r/^[hx][\s.]?264$/i, normalized) || String.match?(normalized, ~r/^avc$/i) ->
        "H.264/AVC"

      # Legacy codecs
      String.match?(normalized, ~r/^xvid$/i) ->
        "XviD"

      String.match?(normalized, ~r/^divx$/i) ->
        "DivX"

      # Modern codecs
      String.match?(normalized, ~r/^vp9$/i) ->
        "VP9"

      String.match?(normalized, ~r/^av1$/i) ->
        "AV1"

      # Hardware encoders
      String.match?(normalized, ~r/^nvenc$/i) ->
        "NVENC"

      # Unknown - return as-is
      true ->
        codec
    end
  end

  # Source Standardization
  defp standardize_source(nil), do: nil

  defp standardize_source(source) do
    normalized = String.downcase(source)

    cond do
      # Blu-ray variants
      String.match?(normalized, ~r/^(bluray|bdrip|brrip)$/i) ->
        "Blu-ray"

      # REMUX
      String.match?(normalized, ~r/^remux$/i) ->
        "Remux"

      # WEB variants (keep distinct)
      String.match?(normalized, ~r/^web-dl$/i) ->
        "WEB-DL"

      String.match?(normalized, ~r/^webrip$/i) ->
        "WEBRip"

      String.match?(normalized, ~r/^web$/i) ->
        "WEB"

      # HDTV
      String.match?(normalized, ~r/^hdtv$/i) ->
        "HDTV"

      # DVD variants
      String.match?(normalized, ~r/^(dvd|dvdrip)$/i) ->
        "DVD"

      # Unknown - return as-is
      true ->
        source
    end
  end

  # Resolution Standardization
  defp standardize_resolution(nil), do: nil

  defp standardize_resolution(resolution) do
    normalized = String.downcase(resolution)

    cond do
      # 4K/2160p
      String.match?(normalized, ~r/^(2160p|4k|uhd)$/i) ->
        "2160p (4K)"

      # 1080p
      String.match?(normalized, ~r/^1080p$/i) ->
        "1080p (Full HD)"

      # 720p
      String.match?(normalized, ~r/^720p$/i) ->
        "720p (HD)"

      # 8K
      String.match?(normalized, ~r/^(4320p|8k)$/i) ->
        "4320p (8K)"

      # 576p/480p (SD)
      String.match?(normalized, ~r/^(576p|480p)$/i) ->
        "#{resolution} (SD)"

      # Unknown - return as-is
      true ->
        resolution
    end
  end

  # HDR Format Standardization
  defp standardize_hdr(nil), do: nil

  defp standardize_hdr(hdr) do
    normalized = String.downcase(hdr)

    cond do
      # HDR10+
      String.contains?(normalized, "hdr10+") ->
        "HDR10+"

      # HDR10
      String.match?(normalized, ~r/^hdr10$/i) ->
        "HDR10"

      # Dolby Vision
      String.match?(normalized, ~r/^(dolbyvision|dovi)$/i) ->
        "Dolby Vision"

      # Generic HDR
      String.match?(normalized, ~r/^hdr$/i) ->
        "HDR"

      # Unknown - return as-is
      true ->
        hdr
    end
  end
end
