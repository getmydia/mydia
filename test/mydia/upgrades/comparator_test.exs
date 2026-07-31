defmodule Mydia.Upgrades.ComparatorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
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

  # A real 4K HDR file as FileAnalyzer would actually write it.
  defp uhd_file do
    %MediaFile{
      resolution: "4K",
      codec: "HEVC (Main 10)",
      audio_codec: "DD+ 5.1",
      hdr_format: "Dolby Vision",
      size: 20 * 1024 * 1024 * 1024,
      analyzed_at: ~U[2026-07-01 00:00:00Z]
    }
  end

  describe "score_file/3" do
    test "scores a real 4K HDR file highly despite analyzer display strings" do
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
        codec: "H.264 (High)",
        audio_codec: "DD+ 5.1",
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
        codec: "HEVC (Main 10)",
        audio_codec: "DD+ 5.1",
        size: 8 * 1024 * 1024 * 1024,
        analyzed_at: ~U[2026-07-01 00:00:00Z]
      }

      bare = %Quality{resolution: "1080p", codec: "x265"}
      sourced = %Quality{resolution: "1080p", codec: "x265", source: "BluRay"}
      size = 8 * 1024 * 1024 * 1024

      # Margin forced to 0: this fixture is identical between file and
      # candidate on every dimension except source (same resolution, codec,
      # size), by design, so the genuine delta is exactly 0 once source is
      # neutralized. The default margin of 5 would reject that zero delta
      # before the equality below ever runs; zeroing it here isolates the
      # thing under test (symmetric neutralization) from the unrelated
      # margin gate, which has its own dedicated tests below.
      {:ok, %{candidate: bare_score}} =
        Comparator.upgrade?(file, bare, size, profile(%{min_upgrade_margin: 0}), :movie)

      {:ok, %{candidate: sourced_score}} =
        Comparator.upgrade?(file, sourced, size, profile(%{min_upgrade_margin: 0}), :movie)

      assert bare_score == sourced_score
    end
  end

  describe "upgrade?/5 margin" do
    test "rejects a candidate that does not clear the margin" do
      file = %MediaFile{
        resolution: "1080p",
        codec: "HEVC (Main 10)",
        audio_codec: "DD+ 5.1",
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
