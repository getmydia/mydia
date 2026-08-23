defmodule Mydia.Upgrades.AttrsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.{FileMetadata, Quality}
  alias Mydia.Upgrades.Attrs

  # A media file exactly as Mydia.Library.apply_analysis/2 writes it: the
  # streaming-normalized codec in the column, the analyzer's own string kept
  # verbatim in metadata.
  defp analyzed(raw) do
    %MediaFile{
      audio_codec: Mydia.Streaming.Codec.normalize_audio_codec(raw),
      metadata: %FileMetadata{audio_codec_raw: raw},
      size: 1024 * 1024
    }
  end

  describe "from_media_file/2 resolution mapping" do
    test "maps the analyzer's 4K to the canonical 2160p" do
      file = %MediaFile{resolution: "4K", size: 1024 * 1024}
      assert %{resolution: "2160p"} = Attrs.from_media_file(file, :movie)
    end

    test "maps 1440p down to the nearest canonical rung, 1080p" do
      file = %MediaFile{resolution: "1440p", size: 1024 * 1024}
      assert %{resolution: "1080p"} = Attrs.from_media_file(file, :movie)
    end

    test "passes through an already canonical resolution" do
      file = %MediaFile{resolution: "1080p", size: 1024 * 1024}
      assert %{resolution: "1080p"} = Attrs.from_media_file(file, :movie)
    end

    test "yields nil for an unmappable resolution rather than guessing" do
      file = %MediaFile{resolution: "potato", size: 1024 * 1024}
      assert %{resolution: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  # Mydia.Library.apply_analysis/2 writes `codec` through
  # Mydia.Streaming.Codec.normalize_video_codec/1, so an analyzed file holds
  # "h264" / "hevc" / "mpeg4", never the analyzer's display string. Only files
  # with analyzed_at set are ever scored, so this is the vocabulary that
  # actually reaches production. The display-string cases below still matter
  # because from_quality/3 parses release titles, which are untouched.
  describe "from_media_file/2 codec mapping, as apply_analysis/2 writes it" do
    test "maps the stored hevc token to the canonical h265" do
      file = %MediaFile{codec: "hevc", size: 1024 * 1024}
      assert %{video_codec: "h265"} = Attrs.from_media_file(file, :movie)
    end

    test "maps the stored h264 token through unchanged" do
      file = %MediaFile{codec: "h264", size: 1024 * 1024}
      assert %{video_codec: "h264"} = Attrs.from_media_file(file, :movie)
    end

    test "maps the stored mpeg4 token, which Codec collapses Xvid and DivX onto" do
      file = %MediaFile{codec: "mpeg4", size: 1024 * 1024}
      assert %{video_codec: "xvid"} = Attrs.from_media_file(file, :movie)
    end

    test "yields nil for a codec no quality profile ranks" do
      file = %MediaFile{codec: "theora", size: 1024 * 1024}
      assert %{video_codec: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 codec mapping" do
    test "strips the profile suffix from an H.264 display name" do
      file = %MediaFile{codec: "H.264 (High)", size: 1024 * 1024}
      assert %{video_codec: "h264"} = Attrs.from_media_file(file, :movie)
    end

    test "strips the profile suffix from an HEVC display name" do
      file = %MediaFile{codec: "HEVC (Main 10)", size: 1024 * 1024}
      assert %{video_codec: "h265"} = Attrs.from_media_file(file, :movie)
    end

    test "lowercases a bare codec name" do
      file = %MediaFile{codec: "AV1", size: 1024 * 1024}
      assert %{video_codec: "av1"} = Attrs.from_media_file(file, :movie)
    end

    test "maps bare x265 to the canonical h265" do
      file = %MediaFile{codec: "x265", size: 1024 * 1024}
      assert %{video_codec: "h265"} = Attrs.from_media_file(file, :movie)
    end

    test "maps bare x264 to the canonical h264" do
      file = %MediaFile{codec: "x264", size: 1024 * 1024}
      assert %{video_codec: "h264"} = Attrs.from_media_file(file, :movie)
    end
  end

  # Production shape. `apply_analysis/2` writes the *normalized* codec to the
  # column ("DD+ 5.1" -> "ac3", "TrueHD Atmos" -> "truehd", channels dropped)
  # and keeps the analyzer's own string in metadata.audio_codec_raw, which is
  # the only place the channel layout and the Atmos distinction survive. Every
  # fixture here carries both, exactly as a real analyzed row does.
  describe "from_media_file/2 audio splitting, as apply_analysis/2 writes it" do
    test "splits a fused codec and channel string into both dimensions" do
      attrs = Attrs.from_media_file(analyzed("DD+ 5.1"), :movie)
      assert attrs.audio_codec == "eac3"
      assert attrs.audio_channels == "5.1"
    end

    test "maps the Stereo label to canonical 2.0" do
      attrs = Attrs.from_media_file(analyzed("AAC Stereo"), :movie)
      assert attrs.audio_codec == "aac"
      assert attrs.audio_channels == "2.0"
    end

    test "maps the Mono label to canonical 1.0" do
      attrs = Attrs.from_media_file(analyzed("AC3 Mono"), :movie)
      assert attrs.audio_codec == "ac3"
      assert attrs.audio_channels == "1.0"
    end

    test "leaves channels nil when the string carries no channel info" do
      attrs = Attrs.from_media_file(analyzed("PCM"), :movie)
      assert attrs.audio_channels == nil
    end

    test "prefers Atmos over TrueHD when a fused string carries both" do
      attrs = Attrs.from_media_file(analyzed("TrueHD Atmos"), :movie)
      assert attrs.audio_codec == "atmos"
      assert attrs.audio_channels == nil
    end

    test "recovers E-AC3 that the streaming column had collapsed onto ac3" do
      file = analyzed("DD+ 5.1")

      # The column really does say "ac3" - the whole reason the raw string is
      # kept. If Attrs read the column, an E-AC3 file would score as plain AC3.
      assert file.audio_codec == "ac3"
      assert Attrs.from_media_file(file, :movie).audio_codec == "eac3"
    end
  end

  # Rows analyzed before metadata.audio_codec_raw existed only have the
  # normalized column. They must still yield a codec; channels stay nil, which
  # Comparator neutralizes symmetrically, so the dimension simply abstains.
  describe "from_media_file/2 audio splitting on a legacy row" do
    test "maps the normalized column when no raw string was recorded" do
      file = %MediaFile{audio_codec: "truehd", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_codec == "truehd"
      assert attrs.audio_channels == nil
    end

    test "maps a normalized dts-hd column" do
      file = %MediaFile{audio_codec: "dts-hd", size: 1024 * 1024}
      assert %{audio_codec: "dts-hd"} = Attrs.from_media_file(file, :movie)
    end

    test "yields nil for a codec no quality profile ranks" do
      file = %MediaFile{audio_codec: "vorbis", size: 1024 * 1024}
      assert %{audio_codec: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 hdr mapping" do
    # REGRESSION: canonical_hdr/1 guarded on is_binary(value), so it silently
    # returned nil for the atom hdr_format now stores, neutralizing HDR on
    # every on-disk file that reaches Mydia.Upgrades.Comparator.
    test "a Dolby Vision 8.1 file yields both the dolby_vision and hdr10 tokens" do
      file = %MediaFile{
        hdr_format: :hdr10,
        dolby_vision_profile: 8,
        dolby_vision_bl_compat_id: 1,
        size: 1024 * 1024
      }

      assert %{hdr_tokens: ["dolby_vision", "hdr10"]} = Attrs.from_media_file(file, :movie)
    end

    test "an HDR10+ file yields the hdr10+ and hdr10 tokens" do
      file = %MediaFile{hdr_format: :hdr10_plus, size: 1024 * 1024}
      assert %{hdr_tokens: ["hdr10+", "hdr10"]} = Attrs.from_media_file(file, :movie)
    end

    test "an SDR file yields no HDR tokens" do
      file = %MediaFile{hdr_format: nil, size: 1024 * 1024}
      assert %{hdr_tokens: []} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 source and size" do
    test "lifts source out of nested metadata to a top level key" do
      file = %MediaFile{metadata: %FileMetadata{source: "BluRay"}, size: 1024 * 1024}
      assert %{source: "BluRay"} = Attrs.from_media_file(file, :movie)
    end

    test "converts bytes to megabytes" do
      file = %MediaFile{size: 8 * 1024 * 1024 * 1024}
      assert %{file_size_mb: 8192} = Attrs.from_media_file(file, :movie)
    end

    test "leaves file_size_mb nil when size is nil" do
      file = %MediaFile{size: nil}
      assert %{file_size_mb: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_quality/3" do
    test "normalizes a parsed release title into the same vocabulary" do
      quality = %Quality{
        resolution: "2160p",
        codec: "x265",
        source: "BluRay",
        hdr_format: nil,
        dolby_vision: true
      }

      attrs = Attrs.from_quality(quality, 20 * 1024 * 1024 * 1024, :movie)

      assert attrs.resolution == "2160p"
      assert attrs.video_codec == "h265"
      assert attrs.source == "BluRay"
      assert attrs.hdr_tokens == ["dolby_vision"]
      assert attrs.file_size_mb == 20_480
    end

    test "leaves unmentioned dimensions nil, but hdr_tokens is always a list" do
      quality = %Quality{resolution: "1080p"}
      attrs = Attrs.from_quality(quality, nil, :movie)

      assert attrs.audio_codec == nil
      assert attrs.audio_channels == nil
      assert attrs.source == nil
      assert attrs.hdr_tokens == []
    end
  end

  # from_media_file/2's metadata_source/1 (attrs.ex:191) reads metadata.source
  # directly - it does not parse relative_path itself, as the "lifts source
  # out of nested metadata" test above already establishes. So these fixtures
  # pre-populate metadata.source with what Mydia.Quality.Sources.detect/1 (the
  # same detector Task 3 wired into QualityProfileEngine.extract_source/1)
  # would derive from the filename, rather than relying on from_media_file/2
  # to parse relative_path itself - it doesn't. That keeps the assertion
  # honest about what is actually under test: canonical_source/1's mapping,
  # not filename inference (which from_media_file/2 does not perform).
  describe "cam-tier sources survive normalization" do
    test "a telesync file normalizes to a cam-tier source, not nil" do
      # Without cam-tier in @canonical_sources this returns nil, the violation
      # in collect_violations/2 requires is_binary(source), and the whole
      # excluded-source mechanism silently no-ops on the upgrade path.
      relative_path =
        "The Odyssey (2026)/The Odyssey (2026) 1080p HQ HDTS - x264 - HQ Clean.mkv"

      detected_source = Mydia.Quality.Sources.detect(relative_path)
      assert detected_source == "Telesync"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264",
        metadata: %FileMetadata{source: detected_source}
      }

      attrs = Attrs.from_media_file(file, :movie)

      assert Mydia.Quality.Sources.cam_tier?(attrs.source),
             "expected a cam-tier source, got #{inspect(attrs.source)}"
    end

    test "clean sources still normalize correctly" do
      relative_path = "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.x264.mkv"
      detected_source = Mydia.Quality.Sources.detect(relative_path)
      assert detected_source == "BluRay"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264",
        metadata: %FileMetadata{source: detected_source}
      }

      assert Attrs.from_media_file(file, :movie).source == "BluRay"
    end
  end

  # R7: a cam-tier file already in the library must score 0 so the upgrade
  # path replaces it once a real release appears. The real shape of a
  # download-imported telesync is metadata.source == nil - V3's
  # ReleaseParser (priv/release_parser/sources.exs) has zero cam-tier
  # entries, so media_import.ex:1642 writes source: nil for exactly the
  # files this feature exists to catch. The tests above pre-populate
  # metadata.source and so never exercise that gap. These do not.
  describe "from_media_file/2 falls back to filename detection when metadata.source is absent" do
    test "a nil metadata.source still detects a cam-tier source from the filename" do
      relative_path =
        "The Odyssey (2026)/The Odyssey (2026) 1080p HQ HDTS - x264 - HQ Clean.mkv"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264",
        metadata: %FileMetadata{source: nil}
      }

      attrs = Attrs.from_media_file(file, :movie)

      assert attrs.source == "Telesync"
    end

    test "an absent metadata still detects a cam-tier source from the filename" do
      relative_path =
        "The Odyssey (2026)/The Odyssey (2026) 1080p HQ HDTS - x264 - HQ Clean.mkv"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264"
      }

      attrs = Attrs.from_media_file(file, :movie)

      assert attrs.source == "Telesync"
    end

    # The fallback must stay scoped to cam-tier detections. Every on-disk
    # file that has no metadata.source today reaches score_source/2 with a
    # nil source and takes the neutral 50.0 catch-all. An unrestricted
    # filename fallback would give every clean file a real source and swing
    # scores by up to +/-9 points (source weight 0.12) against a default
    # upgrade_until_score of 85, churning upgrade decisions library-wide.
    test "a clean file with no metadata.source still yields nil, not BluRay" do
      relative_path = "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.x264.mkv"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264",
        metadata: %FileMetadata{source: nil}
      }

      assert Attrs.from_media_file(file, :movie).source == nil
    end

    test "a file with no source token anywhere in the filename still yields nil" do
      file = %MediaFile{
        relative_path: "Some Show/Some.Show.S01E01.1080p.x264.mkv",
        resolution: "1080p",
        codec: "x264"
      }

      assert Attrs.from_media_file(file, :movie).source == nil
    end

    # End of the chain: a real download-imported telesync (metadata.source
    # nil, exactly what media_import.ex writes today) run through the full
    # pipeline against a profile that excludes Telesync must score 0 and
    # carry the violation, not silently no-op.
    test "a profile excluding Telesync scores a nil-metadata telesync file zero with a violation" do
      relative_path =
        "The Odyssey (2026)/The Odyssey (2026) 1080p HQ HDTS - x264 - HQ Clean.mkv"

      file = %MediaFile{
        relative_path: relative_path,
        resolution: "1080p",
        codec: "x264",
        metadata: %FileMetadata{source: nil}
      }

      attrs = Attrs.from_media_file(file, :movie)

      profile = %Mydia.Settings.QualityProfile{
        name: "Excludes Telesync",
        quality_standards: %{excluded_sources: ["Telesync"]}
      }

      result = Mydia.Settings.QualityProfile.score_media_file(profile, attrs)

      assert result.score == 0.0
      assert [violation] = result.violations
      assert violation =~ "Telesync"
    end
  end
end
