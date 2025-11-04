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
  @sources ~w(BluRay BDRip BRRip WEB WEBRip WEB-DL HDTV DVDRip DVD)
  @codecs ~w(x265 x264 H265 H264 HEVC AVC XviD DivX VP9 AV1)
  @hdr_formats ~w(HDR10+ HDR10 DolbyVision DoVi HDR)
  @audio_codecs ~w(DTS DTS-HD DTS-X Atmos TrueHD AAC AC3 DD5.1 DD+)

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

  # Year pattern - (2020) or .2020.
  @year_pattern ~r/[\(. _-](19\d{2}|20\d{2})[\). _-]/

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
    case parse_tv_show(cleaned) do
      %{type: :tv_show} = result ->
        result

      _ ->
        # Fall back to movie parsing
        parse_movie(cleaned)
    end
    |> Map.put(:original_filename, filename)
  end

  @doc """
  Parses a file name specifically as a movie.

  Returns a parse result with type: :movie or :unknown.
  """
  @spec parse_movie(String.t()) :: parse_result()
  def parse_movie(filename) do
    cleaned = normalize_filename(filename)

    # Extract quality info and release group first
    quality = extract_quality(cleaned)
    release_group = extract_release_group(cleaned)

    # Remove quality markers and release group to isolate title
    title_part = clean_for_title_extraction(cleaned, quality, release_group)

    # Extract year
    year = extract_year(cleaned)

    # Clean up title
    title =
      title_part
      |> remove_year_from_title(year)
      |> clean_title()

    # Calculate confidence
    confidence = calculate_movie_confidence(title, year, quality)

    %{
      type: if(confidence > 0.3, do: :movie, else: :unknown),
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
    text
    |> String.slice(0, match_index)
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
    Enum.find(patterns, fn pattern ->
      String.contains?(text, pattern) ||
        String.contains?(String.downcase(text), String.downcase(pattern))
    end)
  end

  defp clean_for_title_extraction(text, quality, release_group) do
    text
    |> remove_quality_markers(quality)
    |> remove_release_group(release_group)
  end

  defp remove_quality_markers(text, quality) do
    markers =
      [
        quality.resolution,
        quality.source,
        quality.codec,
        quality.hdr_format,
        quality.audio
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce(markers, text, fn marker, acc ->
      String.replace(acc, ~r/#{Regex.escape(marker)}/i, " ")
    end)
  end

  defp remove_release_group(text, nil), do: text

  defp remove_release_group(text, group) do
    String.replace(text, ~r/-#{Regex.escape(group)}$/i, " ")
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
    |> String.trim()
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp calculate_movie_confidence(title, year, quality) do
    base_confidence = 0.5

    confidence =
      base_confidence
      |> add_confidence(title != nil && String.length(title) > 0, 0.2)
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
