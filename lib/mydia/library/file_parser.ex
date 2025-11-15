defmodule Mydia.Library.FileParser do
  @moduledoc """
  Parses media file names to extract structured metadata.

  Handles common naming conventions including:
  - Movies: "Movie Title (2020) [1080p].mkv"
  - TV Shows: "Show.Name.S01E05.720p.WEB.mkv"
  - Scene releases: "Movie.Title.2020.2160p.BluRay.x265-GROUP"
  - Multiple episodes: "Show.S01E01-E03.720p.mkv"

  Uses flexible regex-based pattern matching to handle codec variations
  automatically (e.g., DD5.1, DD51, DDP5.1 all matched by one pattern).

  Returns a struct with parsed information and confidence score.
  """

  require Logger

  alias Mydia.Library.Structs.{ParsedFileInfo, Quality}

  @type media_type :: :movie | :tv_show | :unknown
  @type quality_info :: Quality.t()
  @type parse_result :: ParsedFileInfo.t()

  # Quality patterns - Phase 1: Regex-based patterns
  # Note: Dots are normalized to spaces in filenames, so we need to handle both
  # Audio codec pattern - handles all variations with a single flexible pattern
  @audio_pattern ~r/
    \b
    (?:
      DTS(?:-HD(?:[\s.]MA)?|-X)?          # DTS, DTS-HD, DTS-HD.MA, DTS-HD MA, DTS-X
      |DD(?:P)?(?:\d+[\s.]?\d*)?          # DD, DDP, DD5.1, DD5 1, DD51, DDP5.1, DDP51, DD7.1, etc.
      |EAC3(?:\d+[\s.]?\d*)?              # E-AC3 (same as DDP)
      |TrueHD(?:[\s.]\d+[\s.]?\d*)?       # TrueHD, TrueHD 7.1, TrueHD 7 1
      |Atmos
      |AAC(?:-LC)?(?:[\s.]\d+[\s.]?\d*)?  # AAC, AAC-LC, AAC 2.0
      |AC3
    )
    \b
  /xi

  # Video codec pattern - handles variations like x264, x.264, x 264, h264, h.264
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

  # Resolution pattern - normalize to lowercase 'p' in extract function
  @resolution_pattern ~r/\b(?:\d{3,4}[pP]|4K|8K|UHD)\b/i

  # Source pattern
  @source_pattern ~r/
    \b
    (?:
      REMUX
      |BluRay|BDRip|BRRip
      |WEB(?:-DL|Rip)?                   # WEB, WEB-DL, WEBRip
      |HDTV
      |DVD(?:Rip)?                       # DVD, DVDRip
    )
    \b
  /xi

  # HDR format pattern - handle HDR10+ (+ can be literal or space after normalization)
  # Match HDR10+ without word boundary after + since + is not a word character
  @hdr_pattern ~r/(?:\bHDR10\+|\b(?:DolbyVision|DoVi|HDR10|HDR)\b)/i

  # Additional patterns to strip
  @bit_depth_pattern ~r/\b(8|10|12)[\s-]?bits?\b/i
  @encoder_pattern ~r/[-_. ](NVENC|QSV|AMF|VCE|VideoToolbox)\b/i
  # Only remove brackets that contain quality info (not years)
  @bracket_contents_pattern ~r/\[(HDR|HDR10|HDR10\+|DolbyVision|DoVi|10bit|8bit|x265|x264|HEVC|AVC|2160p|1080p|720p)[^\]]*\]/i
  @extra_noise_pattern ~r/\b(PROPER|REPACK|INTERNAL|LIMITED|UNRATED|DIRECTORS?\.CUT|EXTENDED|THEATRICAL)\b/i
  # Audio channel indicators (after dot normalization)
  @audio_channels_pattern ~r/\b[257]\s+1\b/i
  # VMAF quality metric pattern (e.g., VMAF96, VMAF95.5)
  @vmaf_pattern ~r/\bVMAF\d+(?:\.\d+)?\b/i

  # Common release group patterns (hyphen prefix)
  @release_group_pattern ~r/-([A-Z0-9]+)$/i

  # TV show patterns
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

  # Year pattern - (2020), [2020], or .2020.
  defp year_pattern, do: ~r/[\(\[. _-](19\d{2}|20\d{2})[\)\]. _-]/

  @doc """
  Parses a file name or path and extracts media metadata.

  ## Examples

      iex> FileParser.parse("Movie.Title.2020.1080p.BluRay.x264-GROUP.mkv")
      %{
        type: :movie,
        title: "Movie Title",
        year: 2020,
        quality: %{resolution: "1080p", source: "BluRay", codec: "x264"},
        release_group: "GROUP",
        confidence: 0.95
      }

      iex> FileParser.parse("Show.Name.S01E05.720p.WEB.mkv")
      %{
        type: :tv_show,
        title: "Show Name",
        season: 1,
        episodes: [5],
        quality: %{resolution: "720p", source: "WEB"},
        confidence: 0.9
      }
  """
  @spec parse(String.t()) :: parse_result()
  def parse(filename) when is_binary(filename) do
    # Remove file extension and normalize separators
    cleaned = normalize_filename(filename)

    # Try TV show parsing first (more specific patterns)
    result =
      case parse_tv_show(cleaned) do
        %{type: :tv_show} = result ->
          result

        _ ->
          # Fall back to movie parsing
          parse_movie(cleaned)
      end
      |> Map.put(:original_filename, filename)

    Logger.debug("FileParser parsed file",
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

  @doc """
  Parses a file name specifically as a movie.

  Returns a parse result with type: :movie or :unknown.
  """
  @spec parse_movie(String.t()) :: parse_result()
  def parse_movie(filename) do
    cleaned = normalize_filename(filename)

    # Extract year FIRST, before removing brackets
    year = extract_year(cleaned)

    # Extract quality info and release group
    quality = extract_quality(cleaned)
    release_group = extract_release_group(cleaned)

    # Remove quality markers and release group to isolate title
    title_part = clean_for_title_extraction(cleaned, quality, release_group)

    # Clean up title
    title =
      title_part
      |> remove_year_from_title(year)
      |> clean_title()

    # Calculate confidence
    confidence = calculate_movie_confidence(title, year, quality)

    %{
      type: if(confidence >= 0.5, do: :movie, else: :unknown),
      title: title,
      year: year,
      season: nil,
      episodes: nil,
      quality: quality,
      release_group: release_group,
      confidence: confidence,
      original_filename: filename
    }
  end

  @doc """
  Parses a file name specifically as a TV show.

  Returns a parse result with type: :tv_show or :unknown.
  """
  @spec parse_tv_show(String.t()) :: parse_result()
  def parse_tv_show(filename) do
    cleaned = normalize_filename(filename)

    # Try to match TV patterns
    case match_tv_pattern(cleaned) do
      {:ok, season, episodes, match_index} ->
        # Extract quality info and release group
        quality = extract_quality(cleaned)
        release_group = extract_release_group(cleaned)

        # Extract title (everything before the season/episode pattern)
        title = extract_tv_title(cleaned, match_index)

        # Calculate confidence
        confidence = calculate_tv_confidence(title, season, episodes, quality)

        %{
          type: :tv_show,
          title: title,
          year: extract_year(cleaned),
          season: season,
          episodes: episodes,
          quality: quality,
          release_group: release_group,
          confidence: confidence,
          original_filename: filename
        }

      :error ->
        %{
          type: :unknown,
          title: nil,
          year: nil,
          season: nil,
          episodes: nil,
          quality: %{},
          release_group: nil,
          confidence: 0.0,
          original_filename: filename
        }
    end
  end

  ## Private Functions

  defp normalize_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[_.]/, " ")
    |> String.trim()
  end

  defp match_tv_pattern(text) do
    # Try each TV pattern
    Enum.reduce_while(tv_patterns(), :error, fn pattern, _acc ->
      case Regex.run(pattern, text, return: :index) do
        nil ->
          {:cont, :error}

        [{match_start, _} | captures] ->
          # Extract season and episode numbers from captures
          {season, episodes} = parse_tv_captures(text, captures)
          {:halt, {:ok, season, episodes, match_start}}
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

  defp extract_tv_title(text, match_index) do
    # Extract year first
    year = extract_year(text)

    text
    |> String.slice(0, match_index)
    |> remove_year_from_title(year)
    |> clean_title()
  end

  defp extract_quality(text) do
    %{
      resolution: extract_resolution(text),
      source: extract_with_pattern(text, @source_pattern),
      codec: extract_codec(text),
      hdr_format: extract_hdr(text),
      audio: extract_audio(text)
    }
  end

  # Resolution extraction - normalize case to lowercase 'p'
  defp extract_resolution(text) do
    case Regex.run(@resolution_pattern, text) do
      [match | _] ->
        # Normalize resolution to lowercase 'p' format (1080p not 1080P)
        cond do
          String.match?(match, ~r/^\d+[pP]$/) ->
            String.replace(match, ~r/[pP]$/, "p")

          true ->
            match
        end

      nil ->
        nil
    end
  end

  # Codec extraction - normalize spaces back to dots where appropriate
  defp extract_codec(text) do
    case Regex.run(@codec_pattern, text) do
      [match | _] ->
        # If it's x 264 or h 264, convert back to x.264 or h.264
        # but only if there's a space between letter and number
        if String.match?(match, ~r/^[hxHX]\s26[45]$/i) do
          String.replace(match, " ", ".")
        else
          match
        end

      nil ->
        nil
    end
  end

  # HDR extraction - normalize HDR10+ correctly
  defp extract_hdr(text) do
    case Regex.run(@hdr_pattern, text) do
      [match | _] ->
        # Normalize HDR10+ (+ can be literal or space after normalization)
        # Check if the match contains "HDR10" followed by + or space
        cleaned_match = String.trim(match)

        if String.contains?(cleaned_match, "HDR10+") ||
             String.contains?(cleaned_match, "HDR10 ") do
          "HDR10+"
        else
          cleaned_match
        end

      nil ->
        nil
    end
  end

  # Audio codec extraction - normalize spaces back to dots for channel specs
  defp extract_audio(text) do
    case Regex.run(@audio_pattern, text) do
      [match | _] ->
        # Normalize spaces back to dots for channel specifications (5 1 -> 5.1)
        normalized =
          if String.match?(match, ~r/\d\s\d/) do
            String.replace(match, ~r/(\d)\s(\d)/, "\\1.\\2")
          else
            match
          end

        # Normalize DTS-HD MA to DTS-HD.MA
        normalized =
          if String.match?(normalized, ~r/DTS-HD\sMA/i) do
            String.replace(normalized, ~r/(DTS-HD)\s(MA)/i, "\\1.\\2")
          else
            normalized
          end

        normalized

      nil ->
        nil
    end
  end

  # Generic pattern extraction (for source and others)
  defp extract_with_pattern(text, pattern) do
    case Regex.run(pattern, text) do
      [match | _] -> match
      nil -> nil
    end
  end

  defp extract_release_group(text) do
    case Regex.run(@release_group_pattern, text) do
      [_, group] -> group
      _ -> nil
    end
  end

  defp extract_year(text) do
    case Regex.run(year_pattern(), text) do
      [_, year_str] -> String.to_integer(year_str)
      _ -> nil
    end
  end

  defp clean_for_title_extraction(text, quality, release_group) do
    text
    |> remove_quality_markers(quality)
    |> remove_release_group(release_group)
    |> remove_bit_depth()
    |> remove_encoders()
    |> remove_audio_channels()
    |> remove_vmaf()
    |> remove_bracket_contents()
    |> remove_extra_noise()
  end

  defp remove_quality_markers(text, _quality) do
    # Remove ALL known quality patterns using regex patterns
    # This handles variations automatically (DD5.1, DD51, DDP5.1, etc.)
    # Use :global option to replace all occurrences
    text
    |> String.replace(@audio_pattern, " ", global: true)
    |> String.replace(@codec_pattern, " ", global: true)
    |> String.replace(@resolution_pattern, " ", global: true)
    |> String.replace(@source_pattern, " ", global: true)
    |> String.replace(@hdr_pattern, " ", global: true)
  end

  defp remove_release_group(text, nil), do: text

  defp remove_release_group(text, group) do
    String.replace(text, ~r/-#{Regex.escape(group)}$/i, " ")
  end

  defp remove_bit_depth(text) do
    String.replace(text, @bit_depth_pattern, " ")
  end

  defp remove_encoders(text) do
    String.replace(text, @encoder_pattern, " ")
  end

  defp remove_audio_channels(text) do
    String.replace(text, @audio_channels_pattern, " ")
  end

  defp remove_vmaf(text) do
    String.replace(text, @vmaf_pattern, " ")
  end

  defp remove_bracket_contents(text) do
    text
    |> String.replace(@bracket_contents_pattern, " ")
    |> String.replace(~r/\[\s*\]/, " ")
    |> String.replace(~r/\(\s*\)/, " ")
  end

  defp remove_extra_noise(text) do
    String.replace(text, @extra_noise_pattern, " ")
  end

  defp remove_year_from_title(text, nil), do: text

  defp remove_year_from_title(text, year) do
    text
    |> String.replace(~r/[\(\[. _-]#{year}[\)\]. _-]/, " ")
    |> String.replace(~r/#{year}/, " ")
  end

  defp clean_title(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/[-_]{2,}/, " ")
    |> String.replace(~r/^[-_\s]+|[-_\s]+$/, "")
    |> String.trim()
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == "" || &1 == "-" || &1 == "_" || &1 == "+"))
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp calculate_movie_confidence(title, year, quality) do
    # Require at least some meaningful attributes for classification
    has_year = year != nil
    has_quality = quality.resolution != nil || quality.source != nil || quality.codec != nil
    has_good_title = title != nil && String.length(title) > 3

    # Start with base confidence based on what information we have
    # A movie should have at least a year OR quality markers to be considered valid
    base_confidence =
      cond do
        # No meaningful attributes at all
        !has_good_title && !has_year && !has_quality -> 0.0
        # Has title but missing both year AND quality - likely not a movie
        !has_year && !has_quality -> 0.2
        # Has at least year or quality markers
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
end
