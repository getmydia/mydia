defmodule Mydia.Upgrades.Attrs do
  @moduledoc """
  Normalizes on-disk files and parsed release titles into the single canonical
  vocabulary `Mydia.Settings.QualityProfile.score_media_file/2` validates against.

  This module exists because `Mydia.Library.FileAnalyzer` writes human-readable
  display strings ("H.264 (High)", "DD+ 5.1", "Dolby Vision", "4K") while
  `QualityProfile` matches lowercase tokens ("h264", "eac3", "dolby_vision",
  "2160p"). Scoring a raw `MediaFile` without this mapping scores a genuine 4K
  HDR remux at 25.0 on its heaviest-weighted dimension, below a mediocre 1080p
  file, which would make automatic upgrades actively destructive.

  Unmappable values become `nil` rather than a guess. `nil` is neutralized
  symmetrically by `Mydia.Upgrades.Comparator`, so an unknown dimension never
  favours either side.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.Quality

  @bytes_per_mb 1024 * 1024

  # Analyzer resolution labels that are not canonical rungs. "1440p" clamps
  # down to 1080p: it is closer to 1080p than 2160p in pixel count and
  # clamping up would let a 1440p file masquerade as UHD.
  @resolution_aliases %{
    "4K" => "2160p",
    "4k" => "2160p",
    "UHD" => "2160p",
    "1440p" => "1080p",
    "2K" => "1080p",
    "FHD" => "1080p",
    "HD" => "720p",
    "SD" => "480p"
  }

  @canonical_resolutions ~w(360p 480p 576p 720p 1080p 2160p 4320p)

  @video_codec_aliases %{
    "h.264" => "h264",
    "h264" => "h264",
    "avc" => "h264",
    "x264" => "x264",
    "h.265" => "hevc",
    "h265" => "h265",
    "hevc" => "hevc",
    "x265" => "x265",
    "av1" => "av1",
    "vc1" => "vc1",
    "vc-1" => "vc1",
    "mpeg2" => "mpeg2",
    "mpeg-2" => "mpeg2",
    "xvid" => "xvid",
    "divx" => "divx"
  }

  @audio_codec_aliases %{
    "aac" => "aac",
    "ac3" => "ac3",
    "dd" => "ac3",
    "dd+" => "eac3",
    "eac3" => "eac3",
    "e-ac3" => "eac3",
    "ddp" => "eac3",
    "dts" => "dts",
    "dts-hd" => "dts-hd",
    "dtshd" => "dts-hd",
    "truehd" => "truehd",
    "atmos" => "atmos",
    "flac" => "flac",
    "mp3" => "mp3",
    "opus" => "opus",
    "pcm" => nil
  }

  @channel_aliases %{
    "mono" => "1.0",
    "stereo" => "2.0",
    "1.0" => "1.0",
    "2.0" => "2.0",
    "2.1" => "2.1",
    "5.1" => "5.1",
    "6.1" => "6.1",
    "7.1" => "7.1",
    "7.1.2" => "7.1.2",
    "7.1.4" => "7.1.4"
  }

  @hdr_aliases %{
    "dolby vision" => "dolby_vision",
    "dolbyvision" => "dolby_vision",
    "dv" => "dolby_vision",
    "hdr10+" => "hdr10+",
    "hdr10plus" => "hdr10+",
    "hdr10" => "hdr10",
    "hdr" => "hdr10",
    "hlg" => "hlg"
  }

  @canonical_sources ~w(BluRay REMUX WEB-DL WEBRip HDTV SDTV DVD DVDRip BDRip)

  @doc """
  Normalizes an on-disk `MediaFile` into canonical scoring attributes.
  """
  @spec from_media_file(MediaFile.t(), :movie | :episode) :: map()
  def from_media_file(%MediaFile{} = file, media_type) do
    {audio_codec, audio_channels} = split_audio(file.audio_codec)

    %{
      resolution: canonical_resolution(file.resolution),
      video_codec: canonical_video_codec(file.codec),
      audio_codec: audio_codec,
      audio_channels: audio_channels,
      hdr_format: canonical_hdr(file.hdr_format),
      source: canonical_source(metadata_source(file)),
      file_size_mb: bytes_to_mb(file.size),
      media_type: media_type
    }
  end

  @doc """
  Normalizes a parsed release `Quality` into canonical scoring attributes.

  `size_bytes` comes from the search result rather than the struct, since
  `Quality` carries no size.
  """
  @spec from_quality(Quality.t(), non_neg_integer() | nil, :movie | :episode) :: map()
  def from_quality(%Quality{} = quality, size_bytes, media_type) do
    {audio_codec, audio_channels} = split_audio(quality.audio)

    %{
      resolution: canonical_resolution(quality.resolution),
      video_codec: canonical_video_codec(quality.codec),
      audio_codec: audio_codec,
      audio_channels: audio_channels,
      hdr_format: canonical_hdr(quality.hdr_format),
      source: canonical_source(quality.source),
      file_size_mb: bytes_to_mb(size_bytes),
      media_type: media_type
    }
  end

  defp metadata_source(%MediaFile{metadata: %{source: source}}), do: source
  defp metadata_source(_file), do: nil

  defp canonical_resolution(nil), do: nil

  defp canonical_resolution(value) when is_binary(value) do
    cond do
      value in @canonical_resolutions -> value
      alias_value = Map.get(@resolution_aliases, value) -> alias_value
      true -> nil
    end
  end

  defp canonical_resolution(_), do: nil

  defp canonical_video_codec(nil), do: nil

  defp canonical_video_codec(value) when is_binary(value) do
    value
    |> strip_parenthetical()
    |> String.downcase()
    |> then(&Map.get(@video_codec_aliases, &1))
  end

  defp canonical_video_codec(_), do: nil

  defp canonical_hdr(nil), do: nil

  defp canonical_hdr(value) when is_binary(value) do
    Map.get(@hdr_aliases, String.downcase(String.trim(value)))
  end

  defp canonical_hdr(_), do: nil

  defp canonical_source(nil), do: nil

  defp canonical_source(value) when is_binary(value) do
    Enum.find(@canonical_sources, fn canonical ->
      String.downcase(canonical) == String.downcase(String.trim(value))
    end)
  end

  defp canonical_source(_), do: nil

  # Analyzer writes audio as "<codec> <channels>", e.g. "DD+ 5.1" or
  # "AAC Stereo", and sometimes as a bare codec ("PCM"). Release titles give
  # a bare codec far more often. Both shapes go through here.
  defp split_audio(nil), do: {nil, nil}

  defp split_audio(value) when is_binary(value) do
    tokens = value |> String.trim() |> String.split(~r/\s+/, trim: true)

    channels =
      tokens
      |> Enum.map(&Map.get(@channel_aliases, String.downcase(&1)))
      |> Enum.find(&(&1 != nil))

    codec =
      tokens
      |> Enum.map(&Map.get(@audio_codec_aliases, String.downcase(&1)))
      |> Enum.find(&(&1 != nil))

    {codec, channels}
  end

  defp split_audio(_), do: {nil, nil}

  defp strip_parenthetical(value) do
    value
    |> String.replace(~r/\s*\(.*\)\s*$/, "")
    |> String.trim()
  end

  defp bytes_to_mb(nil), do: nil

  defp bytes_to_mb(bytes) when is_integer(bytes) and bytes >= 0 do
    div(bytes, @bytes_per_mb)
  end

  defp bytes_to_mb(_), do: nil
end
