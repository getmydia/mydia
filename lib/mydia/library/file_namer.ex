defmodule Mydia.Library.FileNamer do
  @moduledoc """
  Generates TRaSH Guides-compatible filenames for media imports.

  This module creates filenames that preserve quality metadata and follow
  TRaSH Guides naming conventions to prevent download loops and ensure
  proper quality tracking.

  ## TRaSH Naming Formats

  **Movies:**
  ```
  {Movie CleanTitle} ({Release Year}) [Edition]{[Quality Full]}{[Audio]}{[HDR]}{[Codec]}{-Release Group}
  ```
  Example: `The Movie Title (2010) [IMAX][Bluray-1080p Proper][DTS 5.1][Dolby Vision][x264]-RlsGrp`

  **TV Shows:**
  ```
  {Series Title} ({Year}) - S{season:00}E{episode:00} - {Episode Title} {[Quality Full]}{[Audio]}{[HDR]}{[Codec]}{-Release Group}
  ```
  Example: `Show Title (2020) - S01E01 - Episode Title [WEB-1080p][DTS 5.1][HDR10][x264]-RlsGrp`
  """

  @doc """
  Generates a filename for a movie.

  ## Parameters
    - `media_item` - The movie media item (must have title and year)
    - `quality_info` - Quality information map with keys: resolution, source, codec, audio, hdr_format, dolby_vision, proper, repack
    - `original_filename` - Original filename (for extension and release group)

  ## Examples

      iex> media_item = %{title: "The Matrix", year: 1999}
      iex> quality = %{resolution: "1080p", source: "BluRay", codec: "x264", audio: "DTS", hdr_format: nil, dolby_vision: false, proper: false, repack: false}
      iex> FileNamer.generate_movie_filename(media_item, quality, "The.Matrix.1999.1080p.BluRay.x264.DTS-GROUP.mkv")
      "The Matrix (1999) [BluRay-1080p][DTS][x264]-GROUP.mkv"
  """
  @spec generate_movie_filename(map(), map(), String.t()) :: String.t()
  def generate_movie_filename(media_item, quality_info, original_filename) do
    extension = Path.extname(original_filename)
    base_name = Path.basename(original_filename, extension)

    # Extract release group from original filename
    release_group = extract_release_group(base_name)

    # Build filename parts (release group handled separately)
    parts = [
      sanitize_title(media_item.title),
      "(#{media_item.year})",
      build_quality_tag(quality_info),
      build_audio_tag(quality_info.audio),
      build_hdr_tag(quality_info),
      build_codec_tag(quality_info.codec)
    ]

    # Join non-nil parts with spaces, then append release group and extension
    base =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    # Append release group (if present) and extension
    base
    |> append_release_group(release_group)
    |> Kernel.<>(extension)
  end

  @doc """
  Generates a filename for a TV episode.

  ## Parameters
    - `media_item` - The TV show media item (must have title)
    - `episode` - The episode record (must have season_number, episode_number, title)
    - `quality_info` - Quality information map with keys: resolution, source, codec, audio, hdr_format, dolby_vision, proper, repack
    - `original_filename` - Original filename (for extension and release group)

  ## Examples

      iex> media_item = %{title: "Breaking Bad", year: 2008}
      iex> episode = %{season_number: 1, episode_number: 1, title: "Pilot"}
      iex> quality = %{resolution: "1080p", source: "BluRay", codec: "x264", audio: nil, hdr_format: nil, dolby_vision: false, proper: false, repack: false}
      iex> FileNamer.generate_episode_filename(media_item, episode, quality, "Breaking.Bad.S01E01.1080p.BluRay.x264-GROUP.mkv")
      "Breaking Bad (2008) - S01E01 - Pilot [BluRay-1080p][x264]-GROUP.mkv"
  """
  @spec generate_episode_filename(map(), map(), map(), String.t()) :: String.t()
  def generate_episode_filename(media_item, episode, quality_info, original_filename) do
    extension = Path.extname(original_filename)
    base_name = Path.basename(original_filename, extension)

    # Extract release group from original filename
    release_group = extract_release_group(base_name)

    # Format season/episode
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    ep_num = String.pad_leading("#{episode.episode_number}", 2, "0")

    # Build filename parts (release group handled separately)
    parts = [
      sanitize_title(media_item.title),
      if(media_item.year, do: "(#{media_item.year})", else: nil),
      "- S#{season}E#{ep_num} -",
      sanitize_title(episode.title),
      build_quality_tag(quality_info),
      build_audio_tag(quality_info.audio),
      build_hdr_tag(quality_info),
      build_codec_tag(quality_info.codec)
    ]

    # Join non-nil parts with spaces, then append release group and extension
    base =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    # Append release group (if present) and extension
    base
    |> append_release_group(release_group)
    |> Kernel.<>(extension)
  end

  @doc """
  Sanitizes a title for use in a filename.

  Removes or replaces characters that are problematic in filenames.

  ## Examples

      iex> FileNamer.sanitize_title("The Matrix: Reloaded")
      "The Matrix - Reloaded"

      iex> FileNamer.sanitize_title("Law & Order")
      "Law and Order"
  """
  @spec sanitize_title(String.t()) :: String.t()
  def sanitize_title(title) when is_binary(title) do
    title
    |> String.replace(":", " -")
    |> String.replace("/", "-")
    |> String.replace("\\", "-")
    |> String.replace("<", "")
    |> String.replace(">", "")
    |> String.replace("\"", "'")
    |> String.replace("|", "-")
    |> String.replace("?", "")
    |> String.replace("*", "")
    |> String.replace("&", "and")
    # Remove multiple spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  ## Private Functions

  defp build_quality_tag(%{
         source: source,
         resolution: resolution,
         proper: proper,
         repack: repack
       }) do
    parts = [
      source,
      resolution,
      if(proper, do: "Proper", else: nil),
      if(repack, do: "Repack", else: nil)
    ]

    tag =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join("-")

    if tag != "", do: "[#{tag}]", else: nil
  end

  defp build_audio_tag(nil), do: nil

  defp build_audio_tag(audio) when is_binary(audio) do
    # Audio format already clean from parser
    "[#{audio}]"
  end

  # Delegates to the one module that produces human HDR text, so the tag
  # here, the GraphQL field, and the LiveView badge cannot drift apart again.
  # `quality_info` is the reshaped Quality struct: hdr_format is an
  # `Hdr.base()` atom or nil, plus a `dolby_vision` boolean. A filename
  # cannot reveal a Dolby Vision profile number, so `dv_profile: 8` below is
  # only an internal marker telling `display/1` to say "Dolby Vision" when
  # `dolby_vision` is true; it is not a claim that the real profile is 8.
  defp build_hdr_tag(quality_info) do
    case Mydia.Library.Hdr.display(%Mydia.Library.Hdr{
           base: Map.get(quality_info, :hdr_format),
           dv_profile: if(Map.get(quality_info, :dolby_vision), do: 8)
         }) do
      nil -> nil
      label -> "[#{label}]"
    end
  end

  defp build_codec_tag(nil), do: nil

  defp build_codec_tag(codec) when is_binary(codec) do
    "[#{codec}]"
  end

  defp append_release_group(base, nil), do: base
  defp append_release_group(base, ""), do: base

  defp append_release_group(base, group) when is_binary(group) do
    "#{base}-#{group}"
  end

  defp extract_release_group(filename) do
    # Release group is usually after the last hyphen
    # Example: "Movie.1080p.BluRay.x264-GROUP" -> "GROUP"
    case String.split(filename, "-") do
      parts when length(parts) > 1 ->
        parts
        |> List.last()
        |> String.trim()
        # Remove common extensions that might be included
        |> String.replace(~r/\.(mkv|mp4|avi)$/i, "")

      _ ->
        nil
    end
  end
end
