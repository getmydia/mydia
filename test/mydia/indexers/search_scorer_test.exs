defmodule Mydia.Indexers.SearchScorerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, SearchResult, SearchScorer}
  alias Mydia.Quality.Attrs
  alias Mydia.Settings.QualityProfile

  # Test Fixtures

  defp build_result(attrs) do
    defaults = %{
      title: "Test.Release.1080p.BluRay.x264",
      size: 5 * 1024 * 1024 * 1024,
      seeders: 50,
      leechers: 10,
      download_url: "magnet:?xt=urn:btih:test",
      indexer: "TestIndexer",
      quality: QualityParser.parse("Test.Release.1080p.BluRay.x264"),
      published_at: DateTime.utc_now()
    }

    Map.merge(defaults, attrs)
    |> then(&struct!(SearchResult, &1))
  end

  defp build_quality_profile(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "Test Profile",
      quality_standards: %{
        preferred_resolutions: ["1080p", "720p"],
        preferred_video_codecs: ["h265", "h264"],
        preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"]
      }
    }

    Map.merge(defaults, attrs)
    |> then(&struct!(QualityProfile, &1))
  end

  describe "score_result/2" do
    test "returns a float score" do
      result = build_result(%{seeders: 50})
      score = SearchScorer.score_result(result, [])

      assert is_float(score)
      assert score >= 0
    end

    test "higher seeders yield higher scores" do
      low_seeder = build_result(%{seeders: 10})
      high_seeder = build_result(%{seeders: 100})

      low_score = SearchScorer.score_result(low_seeder, [])
      high_score = SearchScorer.score_result(high_seeder, [])

      assert high_score > low_score
    end

    test "zero seeders apply a penalty" do
      with_seeders = build_result(%{seeders: 10})
      zero_seeders = build_result(%{seeders: 0})

      with_score = SearchScorer.score_result(with_seeders, [])
      zero_score = SearchScorer.score_result(zero_seeders, [])

      # Zero seeder penalty is 0.7, so zero_score should be less than with_score
      assert zero_score < with_score
    end
  end

  describe "score_result_with_breakdown/2" do
    test "returns a map with score, breakdown, violations, and detected" do
      result = build_result(%{seeders: 50})
      score_result = SearchScorer.score_result_with_breakdown(result, [])

      assert is_map(score_result)
      assert Map.has_key?(score_result, :score)
      assert Map.has_key?(score_result, :breakdown)
      assert Map.has_key?(score_result, :violations)
      assert Map.has_key?(score_result, :detected)
    end

    test "breakdown contains quality_score, seeder_score, and title_bonus" do
      result = build_result(%{seeders: 50})
      score_result = SearchScorer.score_result_with_breakdown(result, [])

      breakdown = score_result.breakdown
      assert Map.has_key?(breakdown, :quality_score)
      assert Map.has_key?(breakdown, :seeder_score)
      assert Map.has_key?(breakdown, :title_bonus)
      assert Map.has_key?(breakdown, :zero_seeder_penalty)
    end

    test "violations includes no seeders message when seeders is 0" do
      result = build_result(%{seeders: 0})
      score_result = SearchScorer.score_result_with_breakdown(result, [])

      assert "No seeders (30% penalty applied)" in score_result.violations
    end

    test "detected contains extracted quality attributes" do
      result =
        build_result(%{
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x265.DTS"),
          size: 8 * 1024 * 1024 * 1024
        })

      score_result = SearchScorer.score_result_with_breakdown(result, [])

      detected = score_result.detected
      assert detected.resolution == "1080p"
      assert detected.source == "BluRay"
      assert is_float(detected.size_mb)
    end
  end

  describe "score_quality/3" do
    test "without quality profile, uses seeders as quality score" do
      # Without a quality profile, seeders determine quality score
      # This prioritizes availability over technical quality
      result = build_result(%{seeders: 100})
      {score, breakdown, violations} = SearchScorer.score_quality(result, nil, :movie)

      # Score is min(seeders, 100) = 100.0
      assert score == 100.0
      assert Map.has_key?(breakdown, :raw_quality_score)
      assert violations == []
    end

    test "without quality profile or quality info, falls back to seeders" do
      result = build_result(%{seeders: 50, quality: nil})
      {score, breakdown, violations} = SearchScorer.score_quality(result, nil, :movie)

      # When no quality info, uses min(seeders, 100)
      assert score == 50.0
      assert Map.has_key?(breakdown, :raw_quality_score)
      assert violations == []
    end

    test "with quality profile, uses QualityProfile scoring" do
      result =
        build_result(%{
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x265"),
          seeders: 50
        })

      profile = build_quality_profile()
      {score, breakdown, _violations} = SearchScorer.score_quality(result, profile, :movie)

      assert is_float(score)
      assert is_map(breakdown)
    end
  end

  describe "score_seeders/1" do
    test "returns 0 for 0 seeders" do
      assert SearchScorer.score_seeders(0) == 0.0
    end

    test "returns 0 for negative seeders" do
      assert SearchScorer.score_seeders(-5) == 0.0
    end

    test "uses logarithmic scale" do
      # log10(10 + 1) * 10 ≈ 10.4
      score_10 = SearchScorer.score_seeders(10)
      # log10(100 + 1) * 10 ≈ 20.0
      score_100 = SearchScorer.score_seeders(100)
      # log10(1000 + 1) * 10 ≈ 30.0
      score_1000 = SearchScorer.score_seeders(1000)

      assert_in_delta score_10, 10.4, 0.1
      assert_in_delta score_100, 20.0, 0.1
      assert_in_delta score_1000, 30.0, 0.1
    end

    test "has diminishing returns" do
      score_100 = SearchScorer.score_seeders(100)
      score_1000 = SearchScorer.score_seeders(1000)

      # 10x more seeders should not give 10x the score
      assert score_1000 < score_100 * 2
    end
  end

  describe "score_title_match/2" do
    test "returns 0 when search_query is nil" do
      assert SearchScorer.score_title_match("Some Title", nil) == 0.0
    end

    test "returns 0 when search_query is empty" do
      assert SearchScorer.score_title_match("Some Title", "") == 0.0
    end

    test "returns higher score for exact match" do
      title = "The.Girlfriend.2025.S01E01.1080p.WEB-DL"
      query = "The Girlfriend S01E01"

      score = SearchScorer.score_title_match(title, query)
      assert score > 0
    end

    test "returns lower score for partial match" do
      exact_title = "The.Girlfriend.2025.S01E01.1080p.WEB-DL"
      partial_title = "The.Girlfriend.Experience.S01E01.1080p.WEB-DL"
      query = "The Girlfriend S01E01"

      exact_score = SearchScorer.score_title_match(exact_title, query)
      partial_score = SearchScorer.score_title_match(partial_title, query)

      assert exact_score > partial_score
    end

    test "quality indicators don't penalize score" do
      title_basic = "Movie.Name.1080p.BluRay.x264"
      title_quality = "Movie.Name.1080p.BluRay.x264.DTS.REMUX"
      query = "Movie Name"

      basic_score = SearchScorer.score_title_match(title_basic, query)
      quality_score = SearchScorer.score_title_match(title_quality, query)

      # Quality indicators should not reduce the score significantly
      assert_in_delta basic_score, quality_score, 2.0
    end
  end

  describe "unified scoring algorithm" do
    test "combined score = (quality * 0.6 + seeders + title) * zero_penalty" do
      result = build_result(%{seeders: 100})
      profile = build_quality_profile()

      opts = [quality_profile: profile, media_type: :movie, search_query: nil]
      score_result = SearchScorer.score_result_with_breakdown(result, opts)

      breakdown = score_result.breakdown
      quality_score = breakdown.quality_score
      seeder_score = breakdown.seeder_score
      title_bonus = breakdown.title_bonus
      penalty = breakdown.zero_seeder_penalty

      expected_score = (quality_score * 0.6 + seeder_score + title_bonus) * penalty

      assert_in_delta score_result.score, expected_score, 0.2
    end

    test "zero seeder penalty reduces score by 30%" do
      result_with_seeders = build_result(%{seeders: 10})
      result_zero_seeders = build_result(%{seeders: 0})

      # For result with seeders, we expect no penalty
      score_with = SearchScorer.score_result_with_breakdown(result_with_seeders, [])
      assert score_with.breakdown.zero_seeder_penalty == 1.0

      # For result without seeders, we expect 0.7 penalty
      score_zero = SearchScorer.score_result_with_breakdown(result_zero_seeders, [])
      assert score_zero.breakdown.zero_seeder_penalty == 0.7
    end
  end

  describe "media_type handling" do
    test "movie type is passed to quality profile scoring" do
      result =
        build_result(%{
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x265"),
          size: 8 * 1024 * 1024 * 1024
        })

      profile = build_quality_profile()

      opts_movie = [quality_profile: profile, media_type: :movie]
      opts_episode = [quality_profile: profile, media_type: :episode]

      score_movie = SearchScorer.score_result(result, opts_movie)
      score_episode = SearchScorer.score_result(result, opts_episode)

      # Both should return valid scores (may be same or different based on profile)
      assert is_float(score_movie)
      assert is_float(score_episode)
    end

    test "defaults to movie when media_type not specified" do
      result = build_result(%{seeders: 50})

      # Without media_type, should default to :movie
      score_result = SearchScorer.score_result_with_breakdown(result, [])

      # Verify we got a valid score
      assert is_float(score_result.score)
    end
  end

  describe "audio channels affect search score" do
    test "preferred channels score higher than non-preferred" do
      profile = %Mydia.Settings.QualityProfile{
        name: "Chan",
        quality_standards: %{
          preferred_resolutions: ["1080p"],
          preferred_audio_channels: ["7.1", "5.1", "2.0"]
        }
      }

      base = fn audio ->
        %Mydia.Indexers.SearchResult{
          title: "Movie 1080p",
          size: 5_000_000_000,
          seeders: 10,
          leechers: 0,
          download_url: "magnet:?x",
          indexer: "test",
          download_protocol: :torrent,
          quality: %Mydia.Library.Structs.Quality{resolution: "1080p", audio: audio}
        }
      end

      {seven_one, _, _} =
        Mydia.Indexers.SearchScorer.score_quality(base.("TrueHD 7.1"), profile, :movie)

      {two_zero, _, _} =
        Mydia.Indexers.SearchScorer.score_quality(base.("AAC 2.0"), profile, :movie)

      assert seven_one > two_zero
    end

    test "codec-then-channels formats (e.g. DDP 5.1) extract correctly" do
      profile = %Mydia.Settings.QualityProfile{
        name: "Chan",
        quality_standards: %{
          preferred_resolutions: ["1080p"],
          preferred_audio_channels: ["7.1", "5.1", "2.0"]
        }
      }

      base = fn audio ->
        %Mydia.Indexers.SearchResult{
          title: "Movie 1080p",
          size: 5_000_000_000,
          seeders: 10,
          leechers: 0,
          download_url: "magnet:?x",
          indexer: "test",
          download_protocol: :torrent,
          quality: %Mydia.Library.Structs.Quality{resolution: "1080p", audio: audio}
        }
      end

      # "DDP 5.1" is the space-delimited "<codec> <channels>" shape every real
      # producer emits (FileAnalyzer's extract_audio_codec/1, "DD+ 5.1"); the
      # glued "DDP5.1" this test used to pass is not producible by either
      # QualityParser.extract_audio/1 (only ever returns a bare codec label,
      # never channels) or FileAnalyzer, so it no longer extracts through
      # Attrs.split_audio/1's whitespace tokenization.
      {ddp_five_one, _, _} =
        Mydia.Indexers.SearchScorer.score_quality(base.("DDP 5.1"), profile, :movie)

      {truehd_five_one, _, _} =
        Mydia.Indexers.SearchScorer.score_quality(base.("TrueHD 5.1"), profile, :movie)

      assert ddp_five_one == truehd_five_one
    end
  end

  describe "real-world scoring scenarios" do
    test "well-seeded BluRay 1080p ranks higher than zero-seeder 4K" do
      bluray_1080p =
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-GoodRelease",
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })

      dead_4k =
        build_result(%{
          title: "Movie.2023.2160p.BluRay.x265-DeadTorrent",
          seeders: 0,
          quality: QualityParser.parse("Movie.2023.2160p.BluRay.x265")
        })

      profile = build_quality_profile()
      opts = [quality_profile: profile, media_type: :movie]

      score_1080p = SearchScorer.score_result(bluray_1080p, opts)
      score_4k = SearchScorer.score_result(dead_4k, opts)

      # Well-seeded 1080p should rank higher than dead 4K
      assert score_1080p > score_4k
    end

    test "matching title ranks higher than similar but different title" do
      exact_match =
        build_result(%{
          title: "The.Girlfriend.2025.S01E01.1080p.WEB-DL",
          seeders: 50
        })

      similar_title =
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01.1080p.WEB-DL",
          seeders: 50
        })

      query = "The Girlfriend S01E01"
      opts = [search_query: query]

      score_exact = SearchScorer.score_result(exact_match, opts)
      score_similar = SearchScorer.score_result(similar_title, opts)

      # Exact match should score higher
      assert score_exact > score_similar
    end
  end

  describe "release_attrs/2" do
    test "is Attrs.from_quality/3 without nil keys for a tagged release" do
      result = build_result(%{})

      expected =
        result.quality
        |> Attrs.from_quality(result.size, :movie)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      assert SearchScorer.release_attrs(result, :movie) == expected
    end

    test "an untagged release is judged as the assumed resolution" do
      title = "Quiet.Harbor.2031.XviD-AFG"
      result = build_result(%{title: title, quality: QualityParser.parse(title)})

      assert SearchScorer.release_attrs(result, :movie).resolution ==
               QualityParser.assumed_resolution()
    end

    test "a release with no parsed quality still has resolution and size" do
      result = build_result(%{quality: nil})
      attrs = SearchScorer.release_attrs(result, :movie)

      assert attrs.resolution == QualityParser.assumed_resolution()
      assert attrs.file_size_mb == div(result.size, 1024 * 1024)
    end
  end

  test "a DTS:X release earns the dts-hd audio preference" do
    profile = build_quality_profile()
    title = "Quiet.Harbor.2031.1080p.BluRay.DTS-X.x264-GRP"
    result = build_result(%{title: title, quality: QualityParser.parse(title)})

    %{breakdown: breakdown} =
      SearchScorer.score_result_with_breakdown(result, quality_profile: profile)

    # "dts-hd" is third of four in the fixture profile's audio list.
    assert breakdown.audio_codec > 25.0
  end
end
