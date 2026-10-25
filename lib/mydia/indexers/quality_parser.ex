defmodule Mydia.Indexers.QualityParser do
  @moduledoc """
  Quality information for indexer release titles, read by
  `Mydia.Library.ReleaseParser`, plus the search-side scoring built on it.

  ## Examples

      iex> QualityParser.parse("Movie.Name.2023.1080p.BluRay.x264.DTS-Group")
      %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      iex> QualityParser.parse("Show.S01E01.2160p.WEB-DL.DDP5.1.HDR.H.265-Group")
      %Quality{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "H.265",
        audio: "DD+ 5.1",
        hdr_format: :hdr10,
        dolby_vision: false,
        proper: false,
        repack: false
      }
  """

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.Quality

  @doc """
  Parses quality information from a release title.

  Returns a Quality struct with nil values for information the title does
  not carry.

  ReleaseParser reads its input as a file path and keeps only the basename.
  Indexer titles are not paths, and some carry a `/` ("1080p / x264"), so it
  is replaced with a space first rather than dropping every token before it.
  """
  @spec parse(String.t()) :: Quality.t()
  def parse(title) when is_binary(title) do
    ReleaseParser.parse(String.replace(title, "/", " ")).quality
  end

  # A release title with no resolution token is SD in practice: the tag is
  # omitted precisely when there is nothing to boast about. `XviD-AFG` and
  # friends are 360p rips.
  @assumed_resolution "360p"

  @doc """
  The resolution to *judge* a release by, with an untagged one assumed to be
  #{@assumed_resolution}.

  `parse/1` stays honest and returns a `nil` resolution when the title
  carries no resolution token, because that output also feeds file renaming
  (`Mydia.Jobs.MediaImport.generate_filename/4` → `FileNamer`), where an
  invented resolution would be written into the filename on disk.

  This function is the search-side reading of the same `nil`. Scoring an
  untagged release as "unknown" gave it a neutral 50 from
  `QualityProfile.score_media_file/2` and no range violation at all, which put
  it *above* an honestly-labelled out-of-range release scoring 25. A 360p XviD
  beat a 720p x265 that way. Call this at the point a release is measured
  against a profile; never when recording what a file actually is.

  ## Examples

      iex> QualityParser.effective_resolution(QualityParser.parse("Movie.1080p.BluRay"))
      "1080p"

      iex> QualityParser.effective_resolution(QualityParser.parse("Movie.XviD-AFG"))
      "360p"

      iex> QualityParser.effective_resolution(nil)
      "360p"
  """
  @spec effective_resolution(Quality.t() | nil) :: String.t()
  def effective_resolution(%Quality{resolution: resolution}) when is_binary(resolution),
    do: resolution

  def effective_resolution(_quality), do: @assumed_resolution

  @doc """
  The resolution assumed for a release title that carries no resolution token.
  """
  @spec assumed_resolution() :: String.t()
  def assumed_resolution, do: @assumed_resolution

  @doc """
  Checks if the release has HDR, including Dolby Vision with no base format.

  ## Examples

      iex> QualityParser.has_hdr?("Movie.2160p.WEB-DL.HDR.x265")
      true

      iex> QualityParser.has_hdr?("Movie.2160p.WEB-DL.DV.x265")
      true

      iex> QualityParser.has_hdr?("Movie.1080p.BluRay.x264")
      false
  """
  @spec has_hdr?(String.t()) :: boolean()
  def has_hdr?(title), do: title |> parse() |> Quality.hdr?()

  @doc """
  Calculates a quality score for ranking purposes.

  Returns a numeric score where higher is better quality.
  Takes into account resolution, source, codec, audio, HDR format, and special tags.

  ## Score Components (per TRaSH Guide tiers)

  - Resolution: 2160p (1000) > 1080p (800) > 720p (600) > lower
  - Source: REMUX (500) > BluRay (450) > WEB-DL (400) > WEBRip (350) > HDTV (300)
  - Video Codec: x265/H.265 (150) > AV1 (140) > x264/H.264 (100)
  - Audio: TrueHD Atmos (200) > DTS:X (190) > TrueHD (180) > DTS-HD MA (170) > etc.,
    whatever channel layout the label carries
  - HDR: Dolby Vision (100) > HDR10+ (80) > HDR10/HLG (60)
  - PROPER/REPACK: +25/+15 bonus

  ## Examples

      iex> quality = Quality.new(resolution: "2160p", source: "BluRay", codec: "x265", dolby_vision: true)
      iex> QualityParser.quality_score(quality)
      1700

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
      hdr_score(quality) +
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
  defp source_score("PDTV"), do: 150
  defp source_score("Telecine"), do: 100
  defp source_score("Telesync"), do: 75
  defp source_score("Screener"), do: 50
  defp source_score("CAM"), do: 25
  defp source_score("Workprint"), do: 25
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

  # Audio labels carry their channel layout ("DD+ 5.1", "TrueHD Atmos 7.1").
  # The tier is the codec, so the layout is dropped before scoring. A bare
  # "Atmos" (no codec beside it) has no tier and scores 0. The strip relies on
  # QualityExtractor emitting channels as "<d>.<d>" after exactly one space.
  defp audio_score(label) when is_binary(label),
    do: label |> String.replace(~r/ \d\.\d$/, "") |> audio_tier_score()

  defp audio_score(_), do: 0

  # Audio codec scoring (per TRaSH Guide tiers)
  # Lossless with object audio > Lossless > High quality lossy > Standard lossy > Compressed
  defp audio_tier_score("TrueHD Atmos"), do: 200
  defp audio_tier_score("DTS:X"), do: 190
  defp audio_tier_score("TrueHD"), do: 180
  defp audio_tier_score("DTS-HD MA"), do: 170
  defp audio_tier_score("DTS-HD"), do: 160
  defp audio_tier_score("FLAC"), do: 150
  defp audio_tier_score("DD+"), do: 120
  defp audio_tier_score("DTS"), do: 100
  defp audio_tier_score("AC3"), do: 80
  defp audio_tier_score("AAC"), do: 60
  defp audio_tier_score("Opus"), do: 50
  defp audio_tier_score("Vorbis"), do: 40
  defp audio_tier_score("MP3"), do: 30
  defp audio_tier_score(_), do: 0

  # HDR scoring (per TRaSH Guide tiers)
  # Dolby Vision > HDR10+ > HDR10/HLG > SDR. A bare "HDR" token canonicalizes
  # to :hdr10 upstream (see Hdr.from_release_token/1), so there is no separate
  # generic-HDR tier left to score.
  defp hdr_score(%Quality{dolby_vision: true}), do: 100
  defp hdr_score(%Quality{hdr_format: :hdr10_plus}), do: 80
  defp hdr_score(%Quality{hdr_format: :hdr10}), do: 60
  defp hdr_score(%Quality{hdr_format: :hlg}), do: 60
  defp hdr_score(%Quality{}), do: 0
end
