defmodule Mydia.Settings.QualityMatcherTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.Structs.Quality
  alias Mydia.Settings.QualityMatcher
  alias Mydia.Settings.QualityProfile

  describe "matches?/2" do
    setup do
      # Create a profile with quality_standards
      profile = %QualityProfile{
        name: "Test HD Profile",
        quality_standards: %{
          preferred_video_codecs: ["h265", "h264"],
          preferred_audio_codecs: ["ac3", "aac"],
          preferred_resolutions: ["1080p", "720p"],
          preferred_sources: ["BluRay", "WEB-DL"],
          movie_min_size_mb: 2048,
          movie_max_size_mb: 15360
        }
      }

      {:ok, profile: profile}
    end

    test "returns {:ok, score} for a high-quality result matching preferences", %{
      profile: profile
    } do
      result = %SearchResult{
        title: "Test Movie 2024 1080p BluRay x265",
        size: 8 * 1024 * 1024 * 1024,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: "BluRay",
          codec: "x265",
          audio: "AC3",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert {:ok, score} = QualityMatcher.matches?(result, profile)
      # Score should be reasonable (above minimum threshold)
      assert score >= 50.0
      assert score <= 100.0
    end

    test "returns {:ok, score} for an acceptable result", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 2024 720p WEB-DL x264",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "720p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert {:ok, score} = QualityMatcher.matches?(result, profile)
      assert score >= 50.0
      assert score <= 100.0
    end

    test "returns {:error, reason} for quality not in allowed list", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 2024 480p WEB-DL x264",
        size: 1 * 1024 * 1024 * 1024,
        seeders: 20,
        leechers: 2,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "480p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert {:error, :quality_not_allowed} = QualityMatcher.matches?(result, profile)
    end

    test "returns {:error, :quality_unknown} for result with no quality", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 2024",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: nil
      }

      assert {:error, :quality_unknown} = QualityMatcher.matches?(result, profile)
    end

    test "returns {:error, violation} when file violates resolution constraints", %{
      profile: profile
    } do
      # Create profile with strict resolution requirements
      profile_with_constraints = %{
        profile
        | quality_standards:
            Map.merge(profile.quality_standards, %{
              min_resolution: "1080p",
              max_resolution: "2160p"
            })
      }

      result = %SearchResult{
        title: "Test Movie 2024 720p BluRay x265",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "720p",
          source: "BluRay",
          codec: "x265",
          audio: "AC3",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert {:error, violation} = QualityMatcher.matches?(result, profile_with_constraints)
      assert is_binary(violation)
      assert String.contains?(violation, "720p") or String.contains?(violation, "below")
    end

    test "handles results with missing quality information gracefully", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 2024 1080p",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: nil,
          codec: nil,
          audio: nil,
          hdr: false,
          proper: false,
          repack: false
        }
      }

      # Should still work with partial quality info
      assert {:ok, score} = QualityMatcher.matches?(result, profile)
      assert score >= 50.0
    end
  end

  describe "calculate_score/2" do
    setup do
      profile = %QualityProfile{
        name: "Test HD Profile",
        quality_standards: %{
          preferred_video_codecs: ["h265", "h264"],
          preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"],
          preferred_resolutions: ["2160p", "1080p"],
          preferred_sources: ["BluRay", "REMUX", "WEB-DL"],
          movie_min_size_mb: 2048,
          movie_max_size_mb: 15360
        }
      }

      {:ok, profile: profile}
    end

    test "returns higher score for better quality matches", %{profile: profile} do
      high_quality = %SearchResult{
        title: "Test Movie 2160p BluRay REMUX h265 Atmos",
        size: 12 * 1024 * 1024 * 1024,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "2160p",
          source: "BluRay",
          codec: "h265",
          audio: "Atmos",
          hdr: true,
          proper: false,
          repack: false
        }
      }

      medium_quality = %SearchResult{
        title: "Test Movie 1080p WEB-DL x264 AAC",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      high_score = QualityMatcher.calculate_score(high_quality, profile)
      medium_score = QualityMatcher.calculate_score(medium_quality, profile)

      # Better quality should score higher
      assert high_score > medium_score
      # Both should be valid scores
      assert high_score >= 0.0 and high_score <= 100.0
      assert medium_score >= 0.0 and medium_score <= 100.0
    end

    test "returns score between 0.0 and 100.0", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 720p",
        size: 2 * 1024 * 1024 * 1024,
        seeders: 10,
        leechers: 1,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "720p",
          source: nil,
          codec: nil,
          audio: nil,
          hdr: false,
          proper: false,
          repack: false
        }
      }

      score = QualityMatcher.calculate_score(result, profile)
      assert score >= 0.0
      assert score <= 100.0
    end

    test "handles profile without quality_standards", %{profile: profile} do
      profile_no_standards = %{profile | quality_standards: nil}

      result = %SearchResult{
        title: "Test Movie 1080p",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      score = QualityMatcher.calculate_score(result, profile_no_standards)
      assert score == 0.0
    end
  end

  describe "is_upgrade?/3" do
    setup do
      profile = %QualityProfile{
        name: "Test Profile",
        upgrades_allowed: true,
        quality_standards: %{preferred_resolutions: ["720p", "1080p", "2160p"]}
      }

      {:ok, profile: profile}
    end

    test "returns true when result quality is better than current", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 1080p",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: "BluRay",
          codec: "x265",
          audio: "AC3",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert QualityMatcher.is_upgrade?(result, profile, "720p")
    end

    test "returns false when upgrades not allowed", %{profile: profile} do
      profile_no_upgrades = %{profile | upgrades_allowed: false}

      result = %SearchResult{
        title: "Test Movie 1080p",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "1080p",
          source: "BluRay",
          codec: "x265",
          audio: "AC3",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      refute QualityMatcher.is_upgrade?(result, profile_no_upgrades, "720p")
    end

    # The resolution-string upgrade ceiling (upgrade_until_quality) was retired
    # in favor of a numeric score cutoff (QualityProfile.upgrade_until_score).
    # is_upgrade?/3 no longer enforces a cap itself; that responsibility moves
    # to the score-based comparator.

    test "returns true when no current quality (first download)", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 720p",
        size: 2 * 1024 * 1024 * 1024,
        seeders: 20,
        leechers: 2,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "720p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      assert QualityMatcher.is_upgrade?(result, profile, nil)
    end

    test "returns false when result quality not in allowed list", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie 480p",
        size: 1 * 1024 * 1024 * 1024,
        seeders: 10,
        leechers: 1,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: %Quality{
          resolution: "480p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      refute QualityMatcher.is_upgrade?(result, profile, "720p")
    end

    test "returns false when result has no quality", %{profile: profile} do
      result = %SearchResult{
        title: "Test Movie",
        size: 4 * 1024 * 1024 * 1024,
        seeders: 50,
        leechers: 5,
        download_url: "magnet:?xt=...",
        indexer: "Test",
        quality: nil
      }

      refute QualityMatcher.is_upgrade?(result, profile, "720p")
    end

    test "uses preferred_resolutions (not qualities) for the allow-list" do
      profile = %Mydia.Settings.QualityProfile{
        name: "Std",
        upgrades_allowed: true,
        quality_standards: %{preferred_resolutions: ["1080p", "720p"]}
      }

      result = %Mydia.Indexers.SearchResult{
        title: "Movie 1080p",
        size: 1_000_000,
        seeders: 10,
        leechers: 1,
        download_url: "magnet:?x",
        indexer: "test",
        quality: %Mydia.Library.Structs.Quality{resolution: "1080p"}
      }

      assert Mydia.Settings.QualityMatcher.is_upgrade?(result, profile, "720p")

      not_allowed = %{result | quality: %Mydia.Library.Structs.Quality{resolution: "480p"}}
      refute Mydia.Settings.QualityMatcher.is_upgrade?(not_allowed, profile, "720p")
    end
  end
end
