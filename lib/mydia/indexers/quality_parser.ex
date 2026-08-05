defmodule Mydia.Indexers.QualityParser do
  @moduledoc """
  Utilities for parsing quality information from release names.

  This module extracts quality metadata from torrent release titles,
  including resolution, source, codec, audio format, and special tags.

  ## Examples

      iex> QualityParser.parse("Movie.Name.2023.1080p.BluRay.x264.DTS-Group")
      %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr: false,
        proper: false,
        repack: false
      }

      iex> QualityParser.parse("Show.S01E01.2160p.WEB-DL.HDR.H.265.AAC-Group")
      %Quality{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "H.265",
        audio: "AAC",
        hdr: true,
        proper: false,
        repack: false
      }
  """

  alias Mydia.Library.Structs.Quality
  alias Mydia.Quality.Sources

  # Resolution patterns (ordered by priority for matching)
  defp resolutions do
    [
      {"2160p", ~r/2160p|4k/i},
      {"1080p", ~r/1080p/i},
      {"720p", ~r/720p/i},
      {"576p", ~r/576p/i},
      {"480p", ~r/480p/i},
      {"360p", ~r/360p/i}
    ]
  end

  # Codec patterns
  defp codecs do
    [
      {"x265", ~r/x\.?265|hevc/i},
      {"x264", ~r/x\.?264/i},
      {"H.265", ~r/h\.265|hevc/i},
      {"H.264", ~r/h\.264|avc/i},
      {"XviD", ~r/xvid/i},
      {"DivX", ~r/divx/i},
      {"VP9", ~r/vp9/i},
      {"AV1", ~r/av1/i}
    ]
  end

  # Audio codec patterns (order matters - more specific patterns first)
  # TRaSH Guide audio tiers: TrueHD Atmos > TrueHD > DTS-HD MA > DTS-HD > DD+ > DTS > AC3 > AAC
  defp audio_codecs do
    [
      # Highest tier: Atmos (object-based audio) - must check before TrueHD
      {"TrueHD Atmos", ~r/truehd.*atmos|atmos.*truehd/i},
      {"DTS:X", ~r/dts[\-\:\s]?x/i},
      # High tier: Lossless
      {"TrueHD", ~r/truehd/i},
      {"DTS-HD MA", ~r/dts[\-\s]?hd[\.\s]?ma/i},
      {"DTS-HD", ~r/dts[\-\s]?hd/i},
      {"FLAC", ~r/flac/i},
      # Mid tier: Lossy but good
      {"DD+", ~r/ddp|dd\+|e[\-\s]?ac[\-\s]?3|dolby[\s]?digital[\s]?plus/i},
      {"DTS", ~r/dts/i},
      {"AC3", ~r/ac3|dd5\.1|dolby[\s]?digital(?![\s]?plus)/i},
      # Low tier: Compressed
      {"AAC", ~r/aac/i},
      {"Opus", ~r/opus/i},
      {"Vorbis", ~r/vorbis/i},
      {"MP3", ~r/mp3/i}
    ]
  end

  # HDR format patterns (order matters - more specific patterns first)
  # TRaSH Guide HDR tiers: DV > HDR10+ > HDR10 > SDR
  defp hdr_formats do
    [
      # Dolby Vision (highest tier) - various naming conventions
      {"DV", ~r/\bDV\b|dolby[\-\s]?vision|dovi/i},
      # HDR10+ (dynamic metadata)
      {"HDR10+", ~r/hdr10\+|hdr10plus|hdr10[\-\s]?plus/i},
      # HDR10 (static metadata) - must come after HDR10+
      {"HDR10", ~r/hdr10(?!\+)/i},
      # Generic HDR (assume HDR10 if not specified)
      {"HDR", ~r/\bHDR\b/i}
    ]
  end

  @doc """
  Parses quality information from a release title.

  Returns a Quality struct with parsed quality information, or nil values for
  information that could not be extracted.

  ## Examples

      iex> QualityParser.parse("Movie.2023.1080p.BluRay.x264")
      %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr: false,
        proper: false,
        repack: false
      }

      iex> QualityParser.parse("Show.S01E01.PROPER.REPACK.1080p.WEB-DL.x265")
      %Quality{
        resolution: "1080p",
        source: "WEB-DL",
        codec: "x265",
        audio: nil,
        hdr: false,
        proper: true,
        repack: true
      }
  """
  @spec parse(String.t()) :: Quality.t()
  def parse(title) when is_binary(title) do
    hdr_format = extract_hdr_format(title)

    Quality.new(
      resolution: extract_resolution(title),
      source: extract_source(title),
      codec: extract_codec(title),
      audio: extract_audio(title),
      hdr: hdr_format != nil,
      hdr_format: hdr_format,
      proper: has_proper?(title),
      repack: has_repack?(title)
    )
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
    resolutions()
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
    Sources.detect(title)
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
    codecs()
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
    audio_codecs()
    |> Enum.find_value(fn {label, pattern} ->
      if Regex.match?(pattern, title), do: label
    end)
  end

  @doc """
  Extracts the specific HDR format from a release title.

  Returns the HDR format string or nil if no HDR detected.
  TRaSH Guide ranking: DV > HDR10+ > HDR10 > HDR > nil (SDR)

  ## Examples

      iex> QualityParser.extract_hdr_format("Movie.2160p.UHD.BluRay.DV.HDR10.HEVC")
      "DV"

      iex> QualityParser.extract_hdr_format("Movie.2160p.UHD.BluRay.HDR10+.HEVC")
      "HDR10+"

      iex> QualityParser.extract_hdr_format("Movie.2160p.WEB-DL.HDR.x265")
      "HDR"

      iex> QualityParser.extract_hdr_format("Movie.1080p.BluRay.x264")
      nil
  """
  @spec extract_hdr_format(String.t()) :: String.t() | nil
  def extract_hdr_format(title) do
    hdr_formats()
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
    extract_hdr_format(title) != nil
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
  Takes into account resolution, source, codec, audio, HDR format, and special tags.

  ## Score Components (per TRaSH Guide tiers)

  - Resolution: 2160p (1000) > 1080p (800) > 720p (600) > lower
  - Source: REMUX (500) > BluRay (450) > WEB-DL (400) > WEBRip (350) > HDTV (300)
  - Video Codec: x265/H.265 (150) > AV1 (140) > x264/H.264 (100)
  - Audio: TrueHD Atmos (200) > DTS:X (190) > TrueHD (180) > DTS-HD MA (170) > etc.
  - HDR Format: DV (100) > HDR10+ (80) > HDR10 (60) > HDR (40)
  - PROPER/REPACK: +25/+15 bonus

  ## Examples

      iex> quality = Quality.new(resolution: "2160p", source: "BluRay", codec: "x265", hdr: true, hdr_format: "DV")
      iex> QualityParser.quality_score(quality)
      1750

      iex> quality = Quality.new(resolution: "1080p", source: "WEB-DL", codec: "x264")
      iex> QualityParser.quality_score(quality)
      1300
  """
  @spec quality_score(Quality.t()) :: integer()
  def quality_score(%Quality{} = quality) do
    resolution_score(quality.resolution) +
      source_score(quality.source) +
      codec_score(quality.codec) +
      audio_score(quality.audio) +
      hdr_format_score(quality.hdr_format) +
      if(quality.proper, do: 25, else: 0) +
      if(quality.repack, do: 15, else: 0)
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

  # Audio codec scoring (per TRaSH Guide tiers)
  # Lossless with object audio > Lossless > High quality lossy > Standard lossy > Compressed
  defp audio_score("TrueHD Atmos"), do: 200
  defp audio_score("DTS:X"), do: 190
  defp audio_score("TrueHD"), do: 180
  defp audio_score("DTS-HD MA"), do: 170
  defp audio_score("DTS-HD"), do: 160
  defp audio_score("FLAC"), do: 150
  defp audio_score("DD+"), do: 120
  defp audio_score("DTS"), do: 100
  defp audio_score("AC3"), do: 80
  defp audio_score("AAC"), do: 60
  defp audio_score("Opus"), do: 50
  defp audio_score("Vorbis"), do: 40
  defp audio_score("MP3"), do: 30
  defp audio_score(_), do: 0

  # HDR format scoring (per TRaSH Guide tiers)
  # DV > HDR10+ > HDR10 > generic HDR > SDR
  defp hdr_format_score("DV"), do: 100
  defp hdr_format_score("HDR10+"), do: 80
  defp hdr_format_score("HDR10"), do: 60
  defp hdr_format_score("HDR"), do: 40
  defp hdr_format_score(_), do: 0
end
