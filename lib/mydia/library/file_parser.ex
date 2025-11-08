defmodule Mydia.Library.FileParser do
  @moduledoc """
  Parses media file names to extract structured metadata.

  Handles common naming conventions including:
  - Movies: "Movie Title (2020) [1080p].mkv"
  - TV Shows: "Show.Name.S01E05.720p.WEB.mkv"
  - Scene releases: "Movie.Title.2020.2160p.BluRay.x265-GROUP"
  - Multiple episodes: "Show.S01E01-E03.720p.mkv"

  Returns a struct with parsed information and confidence score.
  """

  require Logger

  @type media_type :: :movie | :tv_show | :unknown
  @type quality_info :: %{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          hdr_format: String.t() | nil,
          audio: String.t() | nil
        }

  @type parse_result :: %{
          type: media_type(),
          title: String.t() | nil,
          year: integer() | nil,
          season: integer() | nil,
          episodes: [integer()] | nil,
          quality: quality_info(),
          release_group: String.t() | nil,
          confidence: float(),
          original_filename: String.t()
        }

  # Quality patterns
  @resolutions ~w(2160p 1080p 720p 480p 360p 4K 8K UHD)
  @sources ~w(REMUX BluRay BDRip BRRip WEB WEBRip WEB-DL HDTV DVDRip DVD)
  @codecs ~w(x265 x264 H265 H264 HEVC AVC XviD DivX VP9 AV1 NVENC)
  @hdr_formats ~w(HDR10+ HDR10 DolbyVision DoVi HDR)
  @audio_codecs ~w(DTS-HD DTS-X DTS TrueHD DD5.1 DD+ Atmos AAC AC3 DD)

  # Additional patterns to strip
  @bit_depth_pattern ~r/\b(8|10|12)[\s-]?bits?\b/i
  @encoder_pattern ~r/[-_. ](NVENC|QSV|AMF|VCE|VideoToolbox)\b/i
  # Only remove brackets that contain quality info (not years)
  @bracket_contents_pattern ~r/\[(HDR|HDR10|HDR10\+|DolbyVision|DoVi|10bit|8bit|x265|x264|HEVC|AVC|2160p|1080p|720p)[^\]]*\]/i
  @extra_noise_pattern ~r/\b(PROPER|REPACK|INTERNAL|LIMITED|UNRATED|DIRECTORS?\.CUT|EXTENDED|THEATRICAL)\b/i
  # Audio channel indicators (after dot normalization)
  @audio_channels_pattern ~r/\b[257]\s+1\b/i

  # Common release group patterns (hyphen prefix)
  @release_group_pattern ~r/-([A-Z0-9]+)$/i

  # TV show patterns
  @tv_patterns [
    # S01E01 or s01e01, with optional multi-episode S01E01-E03 or S01E01E03
    ~r/[. _-]S(\d{1,2})E(\d{1,2})(?:-?E(\d{1,2}))?/i,
    # 1x01
    ~r/[. _-](\d{1,2})x(\d{1,2})/i,
    # Season 1 Episode 1 (verbose)
    ~r/Season[. _-](\d{1,2})[. _-]Episode[. _-](\d{1,2})/i
  ]

  # Year pattern - (2020), [2020], or .2020.
  @year_pattern ~r/[\(\[. _-](19\d{2}|20\d{2})[\)\]. _-]/

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
    Enum.reduce_while(@tv_patterns, :error, fn pattern, _acc ->
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
      resolution: find_match(text, @resolutions),
      source: find_match(text, @sources),
      codec: find_match(text, @codecs),
      hdr_format: find_match(text, @hdr_formats),
      audio: find_match(text, @audio_codecs)
    }
  end

  defp extract_release_group(text) do
    case Regex.run(@release_group_pattern, text) do
      [_, group] -> group
      _ -> nil
    end
  end

  defp extract_year(text) do
    case Regex.run(@year_pattern, text) do
      [_, year_str] -> String.to_integer(year_str)
      _ -> nil
    end
  end

  defp find_match(text, patterns) do
    # Sort patterns by length (longest first) to match more specific patterns first
    patterns
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find(fn pattern ->
      # For patterns with dots (like DD5.1), also try matching with space (DD5 1)
      # since dots are normalized to spaces in filenames
      normalized_pattern = String.replace(pattern, ".", " ")

      String.contains?(text, pattern) ||
        String.contains?(String.downcase(text), String.downcase(pattern)) ||
        String.contains?(text, normalized_pattern) ||
        String.contains?(String.downcase(text), String.downcase(normalized_pattern))
    end)
  end

  defp clean_for_title_extraction(text, quality, release_group) do
    text
    |> remove_quality_markers(quality)
    |> remove_release_group(release_group)
    |> remove_bit_depth()
    |> remove_encoders()
    |> remove_audio_channels()
    |> remove_bracket_contents()
    |> remove_extra_noise()
  end

  defp remove_quality_markers(text, _quality) do
    # Remove ALL known quality patterns, not just the ones we found
    # This handles cases where files have multiple quality markers
    all_patterns =
      @resolutions ++ @sources ++ @codecs ++ @hdr_formats ++ @audio_codecs

    # Sort by length (longest first) to match more specific patterns first
    all_patterns
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.reduce(text, fn pattern, acc ->
      String.replace(acc, ~r/\b#{Regex.escape(pattern)}\b/i, " ")
    end)
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
    |> Enum.reject(&(&1 == "" || &1 == "-" || &1 == "_"))
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp calculate_movie_confidence(title, year, quality) do
    # Require at least some meaningful attributes for classification
    has_year = year != nil
    has_quality = quality.resolution != nil || quality.source != nil || quality.codec != nil
    has_good_title = title != nil && String.length(title) > 3
    has_multiword_title = title != nil && String.contains?(title, " ")

    # Start with base confidence based on what information we have
    base_confidence =
      cond do
        # No meaningful attributes at all
        !has_good_title && !has_year && !has_quality -> 0.0
        # Just a short/single-word title, nothing else
        !has_year && !has_quality && !has_multiword_title -> 0.2
        # Has some meaningful attributes
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
