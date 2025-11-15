defmodule Mydia.Indexers.ReleaseRankerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}

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

  defp build_results do
    now = DateTime.utc_now()

    [
      # High quality, many seeders, good size
      build_result(%{
        title: "Movie.2023.1080p.BluRay.x264-GoodRelease",
        size: 8 * 1024 * 1024 * 1024,
        seeders: 200,
        quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264"),
        published_at: DateTime.add(now, -7, :day)
      }),
      # 4K but fewer seeders
      build_result(%{
        title: "Movie.2023.2160p.WEB-DL.x265-Group",
        size: 15 * 1024 * 1024 * 1024,
        seeders: 50,
        quality: QualityParser.parse("Movie.2023.2160p.WEB-DL.x265"),
        published_at: DateTime.add(now, -30, :day)
      }),
      # 720p but excellent seeders
      build_result(%{
        title: "Movie.2023.720p.WEB-DL.x264-Popular",
        size: 3 * 1024 * 1024 * 1024,
        seeders: 500,
        quality: QualityParser.parse("Movie.2023.720p.WEB-DL.x264"),
        published_at: DateTime.add(now, -1, :day)
      }),
      # Low seeders, should be filtered by default
      build_result(%{
        title: "Movie.2023.1080p.WEB-DL.x264-Unpopular",
        size: 6 * 1024 * 1024 * 1024,
        seeders: 2,
        quality: QualityParser.parse("Movie.2023.1080p.WEB-DL.x264"),
        published_at: DateTime.add(now, -10, :day)
      }),
      # CAM quality, should rank very low
      build_result(%{
        title: "Movie.2023.CAM.XviD-BadQuality",
        size: 700 * 1024 * 1024,
        seeders: 100,
        quality: QualityParser.parse("Movie.2023.CAM.XviD"),
        published_at: DateTime.add(now, -2, :day)
      })
    ]
  end

  # Tests for select_best_result/2

  describe "select_best_result/2" do
    test "returns the best result based on scoring" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results)

      assert best != nil
      # 2160p should win due to higher quality score
      assert best.result.title == "Movie.2023.2160p.WEB-DL.x265-Group"
      assert best.score > 0
      assert is_map(best.breakdown)
    end

    test "returns nil for empty results" do
      assert ReleaseRanker.select_best_result([]) == nil
    end

    test "respects min_seeders option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, min_seeders: 100)

      assert best != nil
      # Should not return results with < 100 seeders
      assert best.result.seeders >= 100
    end

    test "respects preferred_qualities option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, preferred_qualities: ["720p"])

      assert best != nil
      assert best.result.quality.resolution == "720p"
    end

    test "respects blocked_tags option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, blocked_tags: ["BluRay"])

      assert best != nil
      refute String.contains?(best.result.title, "BluRay")
    end

    test "returns nil when all results are filtered out" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, min_seeders: 10_000)

      assert best == nil
    end
  end

  # Tests for rank_all/2

  describe "rank_all/2" do
    test "returns all results sorted by score" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results)

      # Should filter out the low-seeder result by default (min_seeders: 5)
      assert length(ranked) == 4

      # Scores should be in descending order
      scores = Enum.map(ranked, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "each result includes score breakdown" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results)

      for item <- ranked do
        assert is_map(item.breakdown)
        assert Map.has_key?(item.breakdown, :quality)
        assert Map.has_key?(item.breakdown, :seeders)
        assert Map.has_key?(item.breakdown, :size)
        assert Map.has_key?(item.breakdown, :age)
        assert Map.has_key?(item.breakdown, :tag_bonus)
        assert Map.has_key?(item.breakdown, :total)
        assert item.breakdown.total == item.score
      end
    end

    test "respects preferred_qualities for sorting" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["720p", "1080p"])

      # 720p should come first even if 1080p has higher base score
      first_quality = ranked |> List.first() |> then(& &1.result.quality.resolution)
      assert first_quality == "720p"
    end

    test "applies tag bonus correctly" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.PROPER.x264",
          seeders: 50
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264",
          seeders: 50
        })
      ]

      ranked = ReleaseRanker.rank_all(results, preferred_tags: ["PROPER"])

      # Result with PROPER tag should score higher
      assert List.first(ranked).result.title =~ "PROPER"
      assert List.first(ranked).breakdown.tag_bonus > 0
      assert List.last(ranked).breakdown.tag_bonus == 0
    end

    test "returns empty list for empty input" do
      assert ReleaseRanker.rank_all([]) == []
    end
  end

  # Tests for filter_acceptable/2

  describe "filter_acceptable/2" do
    test "filters by minimum seeders" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 100)

      # Only results with >= 100 seeders should remain (200, 500, 100)
      assert Enum.all?(filtered, fn r -> r.seeders >= 100 end)
      assert length(filtered) == 3
    end

    test "uses default min_seeders of 5" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results)

      # Default should filter out the 2-seeder result
      assert Enum.all?(filtered, fn r -> r.seeders >= 5 end)
      assert length(filtered) == 4
    end

    test "filters by size range" do
      results = build_results()

      # Only accept 2-10 GB
      filtered = ReleaseRanker.filter_acceptable(results, size_range: {2000, 10_000})

      for result <- filtered do
        size_mb = result.size / (1024 * 1024)
        assert size_mb >= 2000
        assert size_mb <= 10_000
      end
    end

    test "filters by blocked tags" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, blocked_tags: ["CAM", "Unpopular"])

      # Should not contain blocked tags
      for result <- filtered do
        refute String.contains?(result.title, "CAM")
        refute String.contains?(result.title, "Unpopular")
      end

      assert length(filtered) < length(results)
    end

    test "blocked tags are case insensitive" do
      results = [
        build_result(%{title: "Movie.CAM.x264", seeders: 50}),
        build_result(%{title: "Movie.cam.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      filtered = ReleaseRanker.filter_acceptable(results, blocked_tags: ["cam"])

      assert length(filtered) == 1
      assert List.first(filtered).title == "Movie.1080p.x264"
    end

    test "applies all filters together" do
      results = build_results()

      filtered =
        ReleaseRanker.filter_acceptable(results,
          min_seeders: 100,
          size_range: {2000, 10_000},
          blocked_tags: ["CAM"]
        )

      # Should pass all criteria
      for result <- filtered do
        assert result.seeders >= 100
        size_mb = result.size / (1024 * 1024)
        assert size_mb >= 2000 && size_mb <= 10_000
        refute String.contains?(result.title, "CAM")
      end
    end

    test "returns empty list when all filtered out" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 10_000)

      assert filtered == []
    end

    test "returns all when no filters specified" do
      results = build_results()

      # With min_seeders: 0 to disable default
      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0)

      assert length(filtered) == length(results)
    end
  end

  # Tests for scoring functions (via breakdown)

  describe "quality scoring" do
    test "higher quality gets higher scores" do
      results = [
        build_result(%{
          title: "Movie.2160p.BluRay.x265",
          seeders: 50,
          quality: QualityParser.parse("Movie.2160p.BluRay.x265")
        }),
        build_result(%{
          title: "Movie.720p.WEB-DL.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.720p.WEB-DL.x264")
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      hq_score = Enum.find(ranked, &(&1.result.quality.resolution == "2160p"))
      lq_score = Enum.find(ranked, &(&1.result.quality.resolution == "720p"))

      assert hq_score.breakdown.quality > lq_score.breakdown.quality
    end

    test "nil quality gets zero score" do
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.quality == 0.0
    end

    test "preferred qualities get bonus" do
      results = [
        build_result(%{
          title: "Movie.1080p.BluRay.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.720p.BluRay.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.720p.BluRay.x264")
        })
      ]

      # Without preference
      without_pref = ReleaseRanker.rank_all(results)
      score_1080p = Enum.find(without_pref, &(&1.result.quality.resolution == "1080p"))

      # With preference for 1080p
      with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      score_1080p_pref = Enum.find(with_pref, &(&1.result.quality.resolution == "1080p"))

      # 1080p should get bonus when preferred
      assert score_1080p_pref.breakdown.quality > score_1080p.breakdown.quality
    end
  end

  describe "seeder scoring" do
    test "more seeders get higher scores" do
      results = [
        build_result(%{seeders: 10, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      scores = Enum.map(ranked, & &1.breakdown.seeders)
      assert scores == Enum.sort(scores, :desc)
    end

    test "zero seeders get zero score" do
      result = build_result(%{seeders: 0})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 0)

      assert List.first(ranked).breakdown.seeders == 0.0
    end

    test "seeder scoring has diminishing returns" do
      results = [
        build_result(%{seeders: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      score_100 = Enum.find(ranked, &(&1.result.seeders == 100)).breakdown.seeders
      score_1000 = Enum.find(ranked, &(&1.result.seeders == 1000)).breakdown.seeders

      # 10x seeders should not give 10x score (diminishing returns)
      assert score_1000 < score_100 * 2
    end
  end

  describe "size scoring" do
    test "reasonable sizes score higher than extremes" do
      results = [
        build_result(%{size: 50 * 1024 * 1024, title: "Small"}),
        build_result(%{size: 5 * 1024 * 1024 * 1024, title: "Good"}),
        build_result(%{size: 30 * 1024 * 1024 * 1024, title: "Huge"})
      ]

      # Allow all sizes for comparison
      opts = [min_seeders: 0, size_range: {0, 100_000}]

      ranked = ReleaseRanker.rank_all([Enum.at(results, 1)], opts)
      good_score = List.first(ranked).breakdown.size

      ranked_small = ReleaseRanker.rank_all([Enum.at(results, 0)], opts)
      small_score = List.first(ranked_small).breakdown.size

      ranked_huge = ReleaseRanker.rank_all([Enum.at(results, 2)], opts)
      huge_score = List.first(ranked_huge).breakdown.size

      assert good_score > small_score
      assert good_score > huge_score
    end

    test "very small files get zero score" do
      result = build_result(%{size: 50 * 1024 * 1024})

      # Allow very small sizes to pass filtering
      ranked = ReleaseRanker.rank_all([result], min_seeders: 0, size_range: {0, 100_000})

      assert List.first(ranked).breakdown.size == 0.0
    end
  end

  describe "age scoring" do
    test "newer releases score higher" do
      now = DateTime.utc_now()

      results = [
        build_result(%{
          published_at: DateTime.add(now, -2, :day),
          title: "Recent"
        }),
        build_result(%{
          published_at: DateTime.add(now, -365, :day),
          title: "Old"
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      recent_score =
        Enum.find(ranked, &String.contains?(&1.result.title, "Recent")).breakdown.age

      old_score = Enum.find(ranked, &String.contains?(&1.result.title, "Old")).breakdown.age

      assert recent_score > old_score
    end

    test "nil published_at gets neutral score" do
      result = build_result(%{published_at: nil})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.age == 50.0
    end

    test "very recent releases get highest age score" do
      result = build_result(%{published_at: DateTime.utc_now()})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.age == 100.0
    end
  end

  describe "tag scoring" do
    test "preferred tags increase score" do
      results = [
        build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      ranked = ReleaseRanker.rank_all(results, preferred_tags: ["PROPER"])

      with_tag = Enum.find(ranked, &String.contains?(&1.result.title, "PROPER"))
      without_tag = Enum.find(ranked, &(!String.contains?(&1.result.title, "PROPER")))

      assert with_tag.breakdown.tag_bonus > 0
      assert without_tag.breakdown.tag_bonus == 0
      assert with_tag.score > without_tag.score
    end

    test "multiple preferred tags stack" do
      result = build_result(%{title: "Movie.PROPER.REPACK.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result], preferred_tags: ["PROPER", "REPACK"])

      # Should get bonus for both tags
      assert List.first(ranked).breakdown.tag_bonus == 50.0
    end

    test "preferred tags are case insensitive" do
      result = build_result(%{title: "Movie.proper.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result], preferred_tags: ["PROPER"])

      assert List.first(ranked).breakdown.tag_bonus > 0
    end

    test "no preferred tags means no bonus" do
      result = build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.tag_bonus == 0
    end
  end

  describe "edge cases" do
    test "handles results with missing quality gracefully" do
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.quality == 0.0
    end

    test "handles results with missing published_at gracefully" do
      result = build_result(%{published_at: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.age == 50.0
    end

    test "handles single result" do
      result = build_result(%{seeders: 50})

      best = ReleaseRanker.select_best_result([result])

      assert best != nil
      assert best.result == result
    end

    test "all scores in breakdown are rounded to 2 decimal places" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # Check that each field value has at most 2 decimal places
      assert Float.round(breakdown.quality, 2) == breakdown.quality
      assert Float.round(breakdown.seeders, 2) == breakdown.seeders
      assert Float.round(breakdown.size, 2) == breakdown.size
      assert Float.round(breakdown.age, 2) == breakdown.age
      assert Float.round(breakdown.tag_bonus, 2) == breakdown.tag_bonus
      assert Float.round(breakdown.total, 2) == breakdown.total
    end

    test "total score matches sum of weighted components" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # Recalculate total from breakdown
      calculated_total =
        breakdown.quality * 0.6 +
          breakdown.seeders * 0.25 +
          breakdown.size * 0.1 +
          breakdown.age * 0.05 +
          breakdown.tag_bonus

      # Allow small rounding difference
      assert_in_delta breakdown.total, calculated_total, 0.1
    end
  end
end
