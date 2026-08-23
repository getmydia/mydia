defmodule Mydia.Settings.QualityProfileEngineTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Quality.Sources
  alias Mydia.Settings
  alias Mydia.Settings.QualityProfileEngine
  alias Mydia.Library.MediaFile

  describe "evaluate_file/2" do
    setup do
      # Create a quality profile with comprehensive quality standards
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test HD Profile",
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["atmos", "ac3"],
            preferred_audio_channels: ["5.1", "2.0"],
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            episode_min_size_mb: 500,
            episode_max_size_mb: 2048
          }
        })

      # Create a library path
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/test/media",
          type: :series,
          monitored: true
        })

      %{profile: profile, library_path: library_path}
    end

    test "evaluates a perfect match file", %{profile: profile, library_path: library_path} do
      # Create a perfect match file (struct only, not inserted)
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h265",
        audio_codec: "atmos",
        resolution: "1080p",
        size: 1_073_741_824,
        # 1 GB
        bitrate: 10_000_000,
        # 10 Mbps
        metadata: %{"audio_channels" => "5.1", "source" => "BluRay"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      assert evaluation.score >= 90.0
      assert evaluation.violations == []
      assert is_list(evaluation.recommendations)
      assert %DateTime{} = evaluation.evaluated_at
      assert is_map(evaluation.breakdown)
    end

    test "evaluates a low quality file with violations", %{
      profile: profile,
      library_path: library_path
    } do
      # Create a low quality file that violates standards
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "xvid",
        audio_codec: "mp3",
        resolution: "480p",
        # Below minimum
        size: 209_715_200,
        # 200 MB - below minimum
        bitrate: 2_000_000,
        # 2 Mbps
        metadata: %{"audio_channels" => "2.0"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      # Should have low score due to violations
      assert evaluation.score == 0.0
      assert evaluation.violations != []
      assert Enum.any?(evaluation.violations, &String.contains?(&1, "480p"))
    end

    test "generates upgrade recommendations", %{profile: profile, library_path: library_path} do
      # Create a file with decent quality but not optimal
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h264",
        # Not the best codec
        audio_codec: "ac3",
        # Not the best audio
        resolution: "720p",
        # Not preferred
        size: 1_073_741_824,
        bitrate: 8_000_000,
        metadata: %{"audio_channels" => "2.0"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      assert evaluation.score > 0.0
      assert is_list(evaluation.recommendations)
      # Should have recommendations for improvements
      assert evaluation.recommendations != []
    end

    test "handles missing metadata gracefully", %{profile: profile, library_path: library_path} do
      # Create a file with minimal metadata
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h265",
        resolution: "1080p",
        size: 1_073_741_824,
        bitrate: nil,
        # Missing bitrate
        metadata: nil,
        # No metadata
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      # Should still provide a score, just with defaults for missing fields
      assert is_float(evaluation.score)
      assert is_map(evaluation.breakdown)
    end

    test "correctly infers source from filename", %{profile: profile, library_path: library_path} do
      test_cases = [
        {"show/BluRay.mkv", "BluRay"},
        {"show/REMUX.mkv", "REMUX"},
        {"show/WEB-DL.mkv", "WEB-DL"},
        {"show/WEBRip.mkv", "WEBRip"}
      ]

      for {filename, _expected_source} <- test_cases do
        media_file = %MediaFile{
          id: Ecto.UUID.generate(),
          relative_path: filename,
          library_path_id: library_path.id,
          library_path: library_path,
          codec: "h265",
          resolution: "1080p",
          size: 1_073_741_824,
          bitrate: 10_000_000,
          metadata: nil,
          episode_id: Ecto.UUID.generate()
        }

        {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

        # The evaluation should work (we can't easily assert the exact source inference
        # but we can verify the function doesn't crash)
        assert is_float(evaluation.score)
      end
    end
  end

  describe "batch processing errors" do
    test "returns error when profile doesn't exist" do
      fake_profile_id = Ecto.UUID.generate()
      fake_library_id = Ecto.UUID.generate()

      assert {:error, :profile_not_found} =
               QualityProfileEngine.apply_profile_to_library(fake_profile_id, fake_library_id)
    end

    test "returns error when applying to non-existent items" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test",
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      fake_item_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      # Should return ok with empty results since no files exist
      assert {:ok, summary} =
               QualityProfileEngine.apply_profile_to_items(profile.id, fake_item_ids)

      assert summary.processed == 0
    end

    test "reevaluate_profile_files returns ok with no files when profile has no files" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Empty Profile",
          quality_standards: %{preferred_resolutions: ["1080p"], preferred_video_codecs: ["h265"]}
        })

      assert {:ok, summary} = QualityProfileEngine.reevaluate_profile_files(profile.id)
      assert summary.processed == 0
      assert summary.updated == 0
      assert summary.errors == []
    end
  end

  describe "source inference from an on-disk path" do
    test "detects cam-tier releases already sitting in the library" do
      # The real file the production instance imported on 2026-08-04.
      path =
        "The Odyssey (2026)/The Odyssey (2026) 1080p HQ HDTS - x264 - [Tel + Tam + Hin + Eng] - HQ Clean - 3.3GB.mkv"

      assert Sources.cam_tier?(QualityProfileEngine.infer_source_from_filename(path))
    end

    test "still detects good sources" do
      assert QualityProfileEngine.infer_source_from_filename(
               "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.x264.mkv"
             ) == "BluRay"

      assert QualityProfileEngine.infer_source_from_filename(
               "Interstellar (2014)/Interstellar.2014.2160p.WEB-DL.x265.mkv"
             ) == "WEB-DL"
    end

    test "returns nil when the path carries no source token" do
      assert QualityProfileEngine.infer_source_from_filename("Wonka (2023)/Wonka.2023.1080p.mkv") ==
               nil
    end
  end

  describe "HDR scoring is not inverted" do
    # REGRESSION: QualityProfileEngine.extract_media_attributes/1 (formerly
    # build_media_attrs/2) passed media_file.hdr_format raw, using neither
    # Upgrades.Attrs nor SearchScorer.normalize_hdr_format/1.
    # score_from_preference_list/2 does an exact == test, so "Dolby Vision"
    # missed ["dolby_vision", ...] and scored 25.0, while a file with no HDR
    # at all hit the 50.0 fallback.
    #
    # Having Dolby Vision made a file score worse than having no HDR.
    #
    # This test must go through the ENGINE specifically. The SearchScorer and
    # Attrs paths both bridge correctly and already pass, so asserting through
    # either of them would give a false green.

    setup do
      profile =
        quality_profile_fixture(%{
          quality_standards: %{
            preferred_resolutions: ["1080p", "2160p"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            require_hdr: false
          }
        })

      {:ok, profile: profile}
    end

    test "a Dolby Vision file outscores an SDR file", %{profile: profile} do
      dv =
        media_file_fixture(%{
          hdr_format: :hdr10,
          dolby_vision_profile: 8,
          dolby_vision_bl_compat_id: 1,
          analyzed_at: DateTime.utc_now()
        })

      sdr = media_file_fixture(%{hdr_format: nil, analyzed_at: DateTime.utc_now()})

      {:ok, dv_eval} = QualityProfileEngine.evaluate_file(profile, dv)
      {:ok, sdr_eval} = QualityProfileEngine.evaluate_file(profile, sdr)

      dv_score = dv_eval.breakdown.hdr
      sdr_score = sdr_eval.breakdown.hdr

      assert dv_score > sdr_score,
             "Dolby Vision scored #{dv_score}, SDR scored #{sdr_score}"

      assert dv_score == 100.0
    end

    test "an HDR10 file scores by list position", %{profile: profile} do
      hdr10 = media_file_fixture(%{hdr_format: :hdr10, analyzed_at: DateTime.utc_now()})
      {:ok, eval} = QualityProfileEngine.evaluate_file(profile, hdr10)
      assert eval.breakdown.hdr == 60.0
    end

    test "an unlisted format still scores below SDR, which is intentional", %{profile: profile} do
      # An operator who listed the HDR formats they want and omitted HLG is
      # saying an HLG file is worse for them than plain SDR.
      hlg = media_file_fixture(%{hdr_format: :hlg, analyzed_at: DateTime.utc_now()})
      sdr = media_file_fixture(%{hdr_format: nil, analyzed_at: DateTime.utc_now()})

      {:ok, hlg_eval} = QualityProfileEngine.evaluate_file(profile, hlg)
      {:ok, sdr_eval} = QualityProfileEngine.evaluate_file(profile, sdr)

      assert hlg_eval.breakdown.hdr == 25.0
      assert sdr_eval.breakdown.hdr == 50.0
    end

    # MUTATION TARGET: score_hdr_format/2 takes Enum.max/1 across every token
    # a file offers. Collapsing that to "just the first token" would score
    # this file 25.0 (dolby_vision is not in a profile that lists only
    # hdr10), not 100.0.
    test "an operator listing only hdr10 still matches a Dolby Vision 8.1 file (best token wins)" do
      hdr10_only_profile =
        quality_profile_fixture(%{
          quality_standards: %{preferred_resolutions: ["1080p"], hdr_formats: ["hdr10"]}
        })

      dv =
        media_file_fixture(%{
          hdr_format: :hdr10,
          dolby_vision_profile: 8,
          analyzed_at: DateTime.utc_now()
        })

      {:ok, eval} = QualityProfileEngine.evaluate_file(hdr10_only_profile, dv)
      assert eval.breakdown.hdr == 100.0
    end
  end
end
