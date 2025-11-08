defmodule Mydia.Indexers.QualityParser do
  @moduledoc """
  Utilities for parsing quality information from release names.

  This module extracts quality metadata from torrent release titles,
  including resolution, source, codec, audio format, and special tags.

  ## Examples

      iex> QualityParser.parse("Movie.Name.2023.1080p.BluRay.x264.DTS-Group")
      %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr: false,
        proper: false,
        repack: false
      }

      iex> QualityParser.parse("Show.S01E01.2160p.WEB-DL.HDR.H.265.AAC-Group")
      %{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "H.265",
        audio: "AAC",
        hdr: true,
        proper: false,
        repack: false
      }
  """

  @type quality_info :: %{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil,
          hdr: boolean(),
          proper: boolean(),
          repack: boolean()
        }

  # Resolution patterns (ordered by priority for matching)
  @resolutions [
    {"2160p", ~r/2160p|4k/i},
    {"1080p", ~r/1080p/i},
    {"720p", ~r/720p/i},
    {"576p", ~r/576p/i},
    {"480p", ~r/480p/i},
    {"360p", ~r/360p/i}
  ]

  # Source patterns
  @sources [
    {"REMUX", ~r/remux/i},
    {"BluRay", ~r/blu[\-\s]?ray|bluray|bdrip|brrip|bd(?:$|[\.\s])/i},
    {"WEB-DL", ~r/web[\-\s]?dl|webdl/i},
    {"WEBRip", ~r/web[\-\s]?rip|webrip/i},
    {"HDTV", ~r/hdtv/i},
    {"SDTV", ~r/sdtv/i},
    {"DVDRip", ~r/dvd[\-\s]?rip|dvdrip/i},
    {"DVD", ~r/dvd/i},
    {"Telecine", ~r/telecine|tc/i},
    {"Telesync", ~r/telesync|ts/i},
    {"CAM", ~r/cam(?:rip)?/i},
    {"Screener", ~r/screener|scr/i},
    {"PDTV", ~r/pdtv/i}
  ]

  # Codec patterns
  @codecs [
    {"x265", ~r/x\.?265|hevc/i},
    {"x264", ~r/x\.?264/i},
    {"H.265", ~r/h\.265|hevc/i},
    {"H.264", ~r/h\.264|avc/i},
    {"XviD", ~r/xvid/i},
    {"DivX", ~r/divx/i},
    {"VP9", ~r/vp9/i},
    {"AV1", ~r/av1/i}
  ]

  # Audio codec patterns (order matters - more specific patterns first)
  @audio_codecs [
    {"Atmos", ~r/atmos/i},
    {"TrueHD", ~r/truehd/i},
    {"DTS-HD", ~r/dts[\-\s]?hd/i},
    {"DTS", ~r/dts/i},
    {"AC3", ~r/ac3|dd(?!p)/i},
    {"AAC", ~r/aac/i},
    {"MP3", ~r/mp3/i},
    {"FLAC", ~r/flac/i},
    {"Opus", ~r/opus/i},
    {"Vorbis", ~r/vorbis/i}
  ]

  @doc """
  Parses quality information from a release title.

  Returns a map with parsed quality information, or nil values for
  information that could not be extracted.

  ## Examples

      iex> QualityParser.parse("Movie.2023.1080p.BluRay.x264")
      %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr: false,
        proper: false,
        repack: false
      }

      iex> QualityParser.parse("Show.S01E01.PROPER.REPACK.1080p.WEB-DL.x265")
      %{
        resolution: "1080p",
        source: "WEB-DL",
        codec: "x265",
        audio: nil,
        hdr: false,
        proper: true,
        repack: true
      }
  """
  @spec parse(String.t()) :: quality_info()
  def parse(title) when is_binary(title) do
    %{
      resolution: extract_resolution(title),
      source: extract_source(title),
      codec: extract_codec(title),
      audio: extract_audio(title),
      hdr: has_hdr?(title),
      proper: has_proper?(title),
      repack: has_repack?(title)
    }
  end

  @doc """
  Extracts the resolution from a release title.

  ## Examples

      iex> QualityParser.extract_resolution("Movie.1080p.BluRay.x264")
      "1080p"

      iex> QualityParser.extract_resolution("Show.S01E01.720p.WEB-DL")
      "720p"

      iex> QualityParser.extract_resolution("Movie.4K.BluRay")
      "2160p"

      iex> QualityParser.extract_resolution("Movie.BluRay.x264")
      nil
  """
  @spec extract_resolution(String.t()) :: String.t() | nil
  def extract_resolution(title) do
    @resolutions
    |> Enum.find_value(fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  @doc """
  Extracts the source from a release title.

  ## Examples

      iex> QualityParser.extract_source("Movie.1080p.BluRay.x264")
      "BluRay"

      iex> QualityParser.extract_source("Show.WEB-DL.1080p")
      "WEB-DL"

      iex> QualityParser.extract_source("Movie.x264")
      nil
  """
  @spec extract_source(String.t()) :: String.t() | nil
  def extract_source(title) do
    @sources
    |> Enum.find_value(fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  @doc """
  Extracts the video codec from a release title.

  ## Examples

      iex> QualityParser.extract_codec("Movie.1080p.BluRay.x264")
      "x264"

      iex> QualityParser.extract_codec("Show.1080p.WEB-DL.H.265")
      "H.265"

      iex> QualityParser.extract_codec("Movie.1080p.BluRay")
      nil
  """
  @spec extract_codec(String.t()) :: String.t() | nil
  def extract_codec(title) do
    @codecs
    |> Enum.find_value(fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  @doc """
  Extracts the audio codec from a release title.

  ## Examples

      iex> QualityParser.extract_audio("Movie.1080p.BluRay.x264.DTS")
      "DTS"

      iex> QualityParser.extract_audio("Show.1080p.WEB-DL.AAC")
      "AAC"

      iex> QualityParser.extract_audio("Movie.1080p.BluRay.x264")
      nil
  """
  @spec extract_audio(String.t()) :: String.t() | nil
  def extract_audio(title) do
    @audio_codecs
    |> Enum.find_value(fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  @doc """
  Checks if the release has HDR.

  ## Examples

      iex> QualityParser.has_hdr?("Movie.2160p.WEB-DL.HDR.x265")
      true

      iex> QualityParser.has_hdr?("Movie.2160p.WEB-DL.DV.x265")
      true

      iex> QualityParser.has_hdr?("Movie.1080p.BluRay.x264")
      false
  """
  @spec has_hdr?(String.t()) :: boolean()
  def has_hdr?(title) do
    Regex.match?(~r/hdr|dolby[\-\s]?vision|dv/i, title)
  end

  @doc """
  Checks if the release is marked as PROPER.

  ## Examples

      iex> QualityParser.has_proper?("Movie.1080p.BluRay.PROPER.x264")
      true

      iex> QualityParser.has_proper?("Movie.1080p.BluRay.x264")
      false
  """
  @spec has_proper?(String.t()) :: boolean()
  def has_proper?(title) do
    Regex.match?(~r/\bproper\b/i, title)
  end

  @doc """
  Checks if the release is marked as REPACK.

  ## Examples

      iex> QualityParser.has_repack?("Movie.1080p.BluRay.REPACK.x264")
      true

      iex> QualityParser.has_repack?("Movie.1080p.BluRay.x264")
      false
  """
  @spec has_repack?(String.t()) :: boolean()
  def has_repack?(title) do
    Regex.match?(~r/\brepack\b/i, title)
  end

  @doc """
  Calculates a quality score for ranking purposes.

  Returns a numeric score where higher is better quality.
  Takes into account resolution, source, codec, and special tags.

  ## Examples

      iex> QualityParser.quality_score(%{resolution: "2160p", source: "BluRay", codec: "x265", hdr: true})
      1650

      iex> QualityParser.quality_score(%{resolution: "1080p", source: "WEB-DL", codec: "x264"})
      860
  """
  @spec quality_score(quality_info()) :: integer()
  def quality_score(quality) do
    resolution_score(quality.resolution) +
      source_score(quality.source) +
      codec_score(quality.codec) +
      if(quality.hdr, do: 50, else: 0) +
      if(quality.proper, do: 10, else: 0) +
      if(quality.repack, do: 5, else: 0)
  end

  # Private helpers

  defp resolution_score("2160p"), do: 1000
  defp resolution_score("1080p"), do: 800
  defp resolution_score("720p"), do: 600
  defp resolution_score("576p"), do: 400
  defp resolution_score("480p"), do: 300
  defp resolution_score("360p"), do: 200
  defp resolution_score(_), do: 0

  defp source_score("REMUX"), do: 500
  defp source_score("BluRay"), do: 450
  defp source_score("WEB-DL"), do: 400
  defp source_score("WEBRip"), do: 350
  defp source_score("HDTV"), do: 300
  defp source_score("DVDRip"), do: 250
  defp source_score("DVD"), do: 200
  defp source_score("SDTV"), do: 150
  defp source_score("Telecine"), do: 100
  defp source_score("Telesync"), do: 75
  defp source_score("Screener"), do: 50
  defp source_score("CAM"), do: 25
  defp source_score(_), do: 0

  defp codec_score("x265"), do: 150
  defp codec_score("H.265"), do: 150
  defp codec_score("AV1"), do: 140
  defp codec_score("x264"), do: 100
  defp codec_score("H.264"), do: 100
  defp codec_score("VP9"), do: 80
  defp codec_score("XviD"), do: 50
  defp codec_score("DivX"), do: 40
  defp codec_score(_), do: 0
end
