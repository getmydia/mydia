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

  ## Two vocabularies, one column

  `Mydia.Library.apply_analysis/2` does not store the analyzer's strings
  verbatim in every column. `resolution` and `hdr_format` land raw ("4K",
  "Dolby Vision"), but `codec` and `audio_codec` are written through
  `Mydia.Streaming.Codec`, which normalizes them for streaming-compatibility
  checks: "H.264 (High)" becomes "h264", "HEVC (Main 10)" becomes "hevc", and
  - lossily for our purposes - "DD+ 5.1" becomes "ac3" and "TrueHD Atmos"
  becomes "truehd", discarding the channel layout entirely.

  Since eligibility requires `analyzed_at IS NOT NULL`, *every* file this
  feature scores holds the post-`Codec` form. This module therefore maps that
  vocabulary, not just the analyzer's display strings: "hevc", "mpeg4" and the
  rest are handled below alongside "HEVC (Main 10)" and "Xvid", because the
  release-title side (`from_quality/3`) still speaks the display vocabulary.

  For audio the mapping alone is not enough, because the channel token is gone
  by the time it reaches the column. `apply_analysis/2` also records the
  analyzer's untouched string in `metadata.audio_codec_raw`, and
  `from_media_file/2` prefers it: that is what makes `audio_channels` (weight
  0.12) and the Atmos-over-TrueHD tie-break contribute anything at all. Files
  analyzed before that field existed fall back to the column and simply score
  with a neutral `audio_channels`, which errs toward not upgrading.

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

  # One canonical value per physical codec, matching the vocabulary
  # `Mydia.Indexers.SearchScorer` and every shipped quality profile already
  # use ("h264"/"h265"). "hevc" and "x265" are release-naming synonyms for
  # h265, not a distinct codec QualityProfile ranks separately; keeping them
  # as separate outputs left every HEVC file and x264/x265 release absent
  # from `preferred_video_codecs`, scoring 25.0 on the heaviest-weighted
  # dimension under every shipped profile.
  @video_codec_aliases %{
    "h.264" => "h264",
    "h264" => "h264",
    "avc" => "h264",
    "x264" => "h264",
    "h.265" => "h265",
    "h265" => "h265",
    "hevc" => "h265",
    "x265" => "h265",
    "av1" => "av1",
    "vc1" => "vc1",
    "vc-1" => "vc1",
    "mpeg2" => "mpeg2",
    "mpeg-2" => "mpeg2",
    "xvid" => "xvid",
    "divx" => "divx",
    # Mydia.Streaming.Codec collapses Xvid and DivX (and any other MPEG-4
    # Part 2 spelling) onto "mpeg4" before the column is written, so that is
    # the form every analyzed file actually holds. The two are
    # indistinguishable by then; "xvid" is the more common of the pair and
    # both score identically under every shipped profile, neither being in
    # any preferred_video_codecs list. Mapping it is still worth doing:
    # leaving it unmapped neutralizes an ancient Xvid rip to the 50.0
    # missing-key default instead of scoring it as the poor codec it is,
    # which suppresses exactly the upgrades this feature exists to find.
    "mpeg4" => "xvid"
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

  @canonical_sources ~w(BluRay REMUX WEB-DL WEBRip HDTV SDTV DVD DVDRip BDRip) ++
                       ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]

  # Precedence for fused audio strings that carry two codec tokens, e.g.
  # FileAnalyzer's "TrueHD Atmos" or "DTS-HD MA". Atmos is a higher-tier
  # object-audio extension of TrueHD and must win even though "TrueHD" is
  # the leftmost token; likewise DTS-HD outranks plain DTS. Earlier entries
  # win ties.
  @audio_codec_priority ~w(atmos truehd dts-hd dts eac3 ac3 flac aac opus mp3)

  @doc """
  Normalizes an on-disk `MediaFile` into canonical scoring attributes.
  """
  @spec from_media_file(MediaFile.t(), :movie | :episode) :: map()
  def from_media_file(%MediaFile{} = file, media_type) do
    {audio_codec, audio_channels} = split_audio(audio_description(file))

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

  # Prefer the analyzer's untouched audio string over the streaming-normalized
  # column: the column has already lost the channel layout ("DD+ 5.1" -> "ac3")
  # and the Atmos distinction ("TrueHD Atmos" -> "truehd"). Files analyzed
  # before metadata.audio_codec_raw existed fall back to the column, which
  # still yields a codec, just no channels.
  defp audio_description(%MediaFile{metadata: %{audio_codec_raw: raw}})
       when is_binary(raw) and raw != "",
       do: raw

  defp audio_description(%MediaFile{audio_codec: audio_codec}), do: audio_codec

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
      |> Enum.reject(&is_nil/1)
      |> highest_priority_codec()

    {codec, channels}
  end

  defp split_audio(_), do: {nil, nil}

  defp highest_priority_codec([]), do: nil
  defp highest_priority_codec(codecs), do: Enum.min_by(codecs, &codec_rank/1)

  defp codec_rank(codec) do
    case Enum.find_index(@audio_codec_priority, &(&1 == codec)) do
      nil -> length(@audio_codec_priority)
      index -> index
    end
  end

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
