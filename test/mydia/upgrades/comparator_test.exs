defmodule Mydia.Upgrades.ComparatorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.Quality
  alias Mydia.Settings.QualityProfile
  alias Mydia.Upgrades.Comparator

  defp profile(overrides \\ %{}) do
    base = %QualityProfile{
      name: "Test",
      upgrades_allowed: true,
      upgrade_until_score: 85,
      min_upgrade_margin: 5,
      quality_standards: %{
        preferred_resolutions: ["2160p", "1080p"],
        # "h265", not "hevc": Attrs collapses every HEVC spelling onto "h265",
        # matching search_scorer.ex and the shipped profiles. A profile
        # preferring "hevc" would never match a real file.
        preferred_video_codecs: ["h265", "h264"],
        preferred_audio_codecs: ["atmos", "eac3", "aac"],
        preferred_audio_channels: ["7.1", "5.1", "2.0"],
        preferred_sources: ["BluRay", "WEB-DL"],
        hdr_formats: ["dolby_vision", "hdr10"]
      }
    }

    struct!(base, overrides)
  end

  # A real 4K HDR file exactly as Mydia.Library.apply_analysis/2 stores one:
  # resolution lands raw from the analyzer, hdr_format holds Hdr's canonical
  # base atom plus the Dolby Vision columns, and codec and audio_codec go
  # through Mydia.Streaming.Codec first ("HEVC (Main 10)" -> "hevc",
  # "DD+ 5.1" -> "ac3", channels dropped). The analyzer's own audio string
  # survives only in metadata.audio_codec_raw, which is where Attrs reads
  # channels and the E-AC3/Atmos distinction from.
  defp uhd_file do
    %MediaFile{
      resolution: "4K",
      codec: "hevc",
      audio_codec: "ac3",
      metadata: %FileMetadata{audio_codec_raw: "DD+ 5.1"},
      hdr_format: :hdr10,
      dolby_vision_profile: 8,
      dolby_vision_bl_compat_id: 1,
      size: 20 * 1024 * 1024 * 1024,
      analyzed_at: ~U[2026-07-01 00:00:00Z]
    }
  end

  describe "score_file/3" do
    test "scores a real 4K HDR file highly despite the stored codec vocabulary" do
      assert {:ok, score} = Comparator.score_file(uhd_file(), profile(), :movie)
      assert score > 70.0
    end

    test "refuses to score a file with no analyzed_at" do
      file = %MediaFile{uhd_file() | analyzed_at: nil}
      assert {:error, :unscorable} = Comparator.score_file(file, profile(), :movie)
    end

    test "refuses to score against a profile with no quality standards" do
      assert {:error, :unscorable} =
               Comparator.score_file(uhd_file(), profile(%{quality_standards: nil}), :movie)
    end

    # Task 10 review finding 4: the score_file_with_breakdown/3 refactor
    # briefly collapsed the analyzed_at-nil clause into the general one,
    # requiring `%QualityProfile{}` unconditionally. That turned an
    # unanalyzed file scored against a nil profile from a graceful
    # {:error, :unscorable} into a FunctionClauseError — reachable because
    # upgrade?/5 below passes `profile` through to score_file/3 unguarded.
    test "refuses to score a file with no analyzed_at even when the profile is nil, without raising" do
      file = %MediaFile{uhd_file() | analyzed_at: nil}
      assert {:error, :unscorable} = Comparator.score_file(file, nil, :movie)
    end
  end

  describe "score_file_with_breakdown/3" do
    test "returns the same score as score_file/3, plus a per-dimension breakdown" do
      assert {:ok, score} = Comparator.score_file(uhd_file(), profile(), :movie)

      assert {:ok, %{score: ^score, breakdown: breakdown}} =
               Comparator.score_file_with_breakdown(uhd_file(), profile(), :movie)

      assert is_map(breakdown)
      assert Map.has_key?(breakdown, :resolution)
    end

    test "refuses to score a file with no analyzed_at" do
      file = %MediaFile{uhd_file() | analyzed_at: nil}
      assert {:error, :unscorable} = Comparator.score_file_with_breakdown(file, profile(), :movie)
    end

    test "refuses to score against a profile with no quality standards" do
      assert {:error, :unscorable} =
               Comparator.score_file_with_breakdown(
                 uhd_file(),
                 profile(%{quality_standards: nil}),
                 :movie
               )
    end
  end

  describe "upgrade?/5 symmetric neutralization" do
    test "a terse title is not penalized for omitting audio" do
      # Candidate mentions only resolution/codec/source. Audio must be
      # inherited from the file so it contributes zero delta.
      candidate = %Quality{resolution: "2160p", codec: "x265", source: "BluRay"}

      file = %MediaFile{
        resolution: "1080p",
        codec: "h264",
        audio_codec: "ac3",
        metadata: %FileMetadata{audio_codec_raw: "DD+ 5.1"},
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      assert {:ok, %{delta: delta}} =
               Comparator.upgrade?(file, candidate, 20 * 1024 * 1024 * 1024, profile(), :movie)

      assert delta > 0
    end

    test "a dimension the file lacks cannot favour the candidate" do
      # File has no source at all. Candidate advertises BluRay. Source must be
      # neutralized on both sides, so it contributes nothing to the delta.
      file = %MediaFile{
        resolution: "1080p",
        codec: "h264",
        audio_codec: "eac3",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      # Both candidates carry the same genuine h264 -> h265 improvement, so
      # both clear the gate and expose their score; the *only* difference
      # between them is the source the file cannot match. If source were not
      # neutralized symmetrically, `sourced` would score higher purely for
      # mentioning BluRay.
      bare = %Quality{resolution: "1080p", codec: "x265"}
      sourced = %Quality{resolution: "1080p", codec: "x265", source: "BluRay"}
      size = 8 * 1024 * 1024 * 1024

      {:ok, %{candidate: bare_score}} =
        Comparator.upgrade?(file, bare, size, profile(), :movie)

      {:ok, %{candidate: sourced_score}} =
        Comparator.upgrade?(file, sourced, size, profile(), :movie)

      assert bare_score == sourced_score
    end
  end

  describe "upgrade?/5 margin" do
    # Whole-branch review finding 4: `delta >= margin` with a margin of 0
    # accepts a delta of exactly 0.0, so an identical-quality release is
    # grabbed and the current file trashed. The replacement then scores the
    # same, making the item eligible again tomorrow - a churn loop the
    # blacklist cannot stop, because the gate *passes*. A margin of 0 must
    # mean "any genuine improvement", not "no improvement at all".
    test "an exact tie is not an upgrade even when the margin is 0" do
      file = %MediaFile{
        resolution: "1080p",
        codec: "hevc",
        audio_codec: "eac3",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      identical = %Quality{resolution: "1080p", codec: "x265"}

      assert {:error, :below_margin} =
               Comparator.upgrade?(
                 file,
                 identical,
                 8 * 1024 * 1024 * 1024,
                 profile(%{min_upgrade_margin: 0}),
                 :movie
               )
    end

    test "an exact tie is not an upgrade when the margin is nil" do
      file = %MediaFile{
        resolution: "1080p",
        codec: "hevc",
        audio_codec: "eac3",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      identical = %Quality{resolution: "1080p", codec: "x265"}

      assert {:error, :below_margin} =
               Comparator.upgrade?(
                 file,
                 identical,
                 8 * 1024 * 1024 * 1024,
                 profile(%{min_upgrade_margin: nil}),
                 :movie
               )
    end

    test "a genuine improvement still passes a margin of 0" do
      file = %MediaFile{
        resolution: "720p",
        codec: "hevc",
        audio_codec: "eac3",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      better = %Quality{resolution: "2160p", codec: "x265"}

      assert {:ok, %{delta: delta}} =
               Comparator.upgrade?(
                 file,
                 better,
                 8 * 1024 * 1024 * 1024,
                 profile(%{min_upgrade_margin: 0}),
                 :movie
               )

      assert delta > 0
    end

    test "rejects a candidate that does not clear the margin" do
      file = %MediaFile{
        resolution: "1080p",
        codec: "hevc",
        audio_codec: "ac3",
        metadata: %FileMetadata{audio_codec_raw: "DD+ 5.1"},
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      identical = %Quality{resolution: "1080p", codec: "x265"}

      assert {:error, :below_margin} =
               Comparator.upgrade?(
                 file,
                 identical,
                 8 * 1024 * 1024 * 1024,
                 profile(%{min_upgrade_margin: 5}),
                 :movie
               )
    end
  end

  describe "HDR signal reaches Comparator" do
    # REGRESSION: Mydia.Upgrades.Attrs.canonical_hdr/1 guarded on
    # is_binary(value). MediaFile.hdr_format and Quality.hdr_format both
    # store the Hdr module's canonical base atom (:hdr10, :hdr10_plus, :hlg),
    # never a string, so that guard silently returned nil for every real
    # file and release. Every analyzed file scored the same 50.0 fallback on
    # the hdr dimension through this module regardless of its actual HDR
    # status, neutralizing quality_standards.hdr_formats for the entire
    # upgrade sweep.
    test "a Dolby Vision file scores higher on the hdr dimension than an SDR file" do
      p = profile()

      sdr_file = %MediaFile{
        uhd_file()
        | hdr_format: nil,
          dolby_vision_profile: nil,
          dolby_vision_bl_compat_id: nil
      }

      {:ok, %{breakdown: dv_breakdown}} =
        Comparator.score_file_with_breakdown(uhd_file(), p, :movie)

      {:ok, %{breakdown: sdr_breakdown}} =
        Comparator.score_file_with_breakdown(sdr_file, p, :movie)

      assert dv_breakdown.hdr > sdr_breakdown.hdr
    end

    test "a candidate release carrying Dolby Vision beats the same file with no HDR at all" do
      p = profile(%{min_upgrade_margin: 0})

      file = %MediaFile{
        resolution: "1080p",
        codec: "h264",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      dv_candidate = %Quality{resolution: "1080p", codec: "h264", dolby_vision: true}

      assert {:ok, %{delta: delta}} =
               Comparator.upgrade?(file, dv_candidate, 8 * 1024 * 1024 * 1024, p, :movie)

      assert delta > 0
    end
  end

  describe "below_cutoff?/3" do
    test "a file at or above the cutoff is not eligible" do
      refute Comparator.below_cutoff?(uhd_file(), profile(%{upgrade_until_score: 10}), :movie)
    end

    test "a file under the cutoff is eligible" do
      assert Comparator.below_cutoff?(uhd_file(), profile(%{upgrade_until_score: 100}), :movie)
    end

    test "an unscorable file is never eligible" do
      file = %MediaFile{uhd_file() | analyzed_at: nil}
      refute Comparator.below_cutoff?(file, profile(%{upgrade_until_score: 100}), :movie)
    end

    test "a profile with upgrades disabled is never eligible" do
      refute Comparator.below_cutoff?(
               uhd_file(),
               profile(%{upgrades_allowed: false, upgrade_until_score: 100}),
               :movie
             )
    end
  end
end
