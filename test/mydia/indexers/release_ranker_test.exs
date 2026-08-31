defmodule Mydia.Indexers.ReleaseRankerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}
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

  # Note: ReleaseRanker uses the unified SearchScorer algorithm for all scoring.
  # The breakdown struct surfaces the real file-size sub-score (from the quality
  # profile) under `:size`, and the raw 0-10 title bonus under `:title_match`
  # (no longer inflated ×100). `:age` and `:tag_bonus` remain 0.0 because the
  # unified formula has no separate age or tag component. Soft-penalty fields
  # (`:size_penalty`, `:seeder_penalty`, `:identity_penalty`) default to 0.0 and
  # are only non-zero when the corresponding ranking option fires.

  # Tests for select_best_result/2

  describe "select_best_result/2" do
    test "returns the best result based on scoring" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results)

      assert best != nil
      # With unified scoring (no quality_profile), the result with most seeders wins
      # 720p has 500 seeders, which gives highest seeder score
      assert best.result.title == "Movie.2023.720p.WEB-DL.x264-Popular"
      assert best.score > 0
      assert is_map(best.breakdown)
    end

    test "returns nil for empty results" do
      assert ReleaseRanker.select_best_result([]) == nil
    end

    test "min_seeders no longer removes low-seeder results (soft penalty)" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, min_seeders: 100)

      assert best != nil
      # Low-seeder releases are penalized, not removed, so a high-seeder release
      # still wins on score even with min_seeders set.
      assert best.result.seeders >= 100

      # All five releases survive ranking now.
      ranked = ReleaseRanker.rank_all(results, min_seeders: 100)
      assert length(ranked) == 5
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

    test "still returns a (penalized) result when all are below min_seeders" do
      results = build_results()

      # Previously min_seeders: 10_000 removed everything and returned nil. Now
      # seeders is a soft penalty, so the best-scoring (penalized) release is
      # still selectable rather than nothing being grabbed.
      best = ReleaseRanker.select_best_result(results, min_seeders: 10_000)

      assert best != nil
      assert best.breakdown.seeder_penalty < 0.0
    end
  end

  # Tests for rank_all/2

  describe "rank_all/2 rejects malicious releases" do
    test "drops a release with a suspicious executable extension before scoring" do
      # The exact malware filename from the production incident: a 1.3GB PE32
      # executable padded to look like a 1080p video release. Before this fix it
      # scored highest and was grabbed; the validator only logged a warning.
      malware =
        build_result(%{
          title: "Your.Friends.and.Neighbors.S02E05.1080p.WEB.h264-ETHEL.exe",
          seeders: 500
        })

      legit =
        build_result(%{
          title: "Your.Friends.and.Neighbors.S02E05.1080p.WEB.h264-GROUP.mkv",
          seeders: 5
        })

      ranked = ReleaseRanker.rank_all([malware, legit])

      titles = Enum.map(ranked, & &1.result.title)
      refute "Your.Friends.and.Neighbors.S02E05.1080p.WEB.h264-ETHEL.exe" in titles
      assert "Your.Friends.and.Neighbors.S02E05.1080p.WEB.h264-GROUP.mkv" in titles
    end

    test "select_best_result never returns a suspicious executable release" do
      malware =
        build_result(%{
          title: "Your.Friends.and.Neighbors.S02E08.1080p.WEB.h264-ETHEL.scr",
          seeders: 999
        })

      legit =
        build_result(%{
          title: "Your.Friends.and.Neighbors.S02E08.1080p.WEB.h264-GROUP.mkv",
          seeders: 1
        })

      best = ReleaseRanker.select_best_result([malware, legit])

      assert best.result.title == "Your.Friends.and.Neighbors.S02E08.1080p.WEB.h264-GROUP.mkv"
    end

    test "returns empty when every candidate is a suspicious executable" do
      results = [
        build_result(%{title: "From.S04E06.1080p.WEB.h264-ETHEL.exe", seeders: 500}),
        build_result(%{title: "From.S04E06.1080p.WEB.h264-ETHEL.scr", seeders: 400})
      ]

      assert ReleaseRanker.rank_all(results) == []
    end
  end

  describe "rank_all/2" do
    test "returns all results sorted by score" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results)

      # Default min_seeders is 0, so all results should be returned
      assert length(ranked) == 5

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
        assert Map.has_key?(item.breakdown, :title_match)
        assert Map.has_key?(item.breakdown, :tag_bonus)
        assert Map.has_key?(item.breakdown, :total)
        assert item.breakdown.total == item.score

        # New soft-penalty fields default to 0.0 when no penalty applies
        assert item.breakdown.size_penalty == 0.0
        assert item.breakdown.seeder_penalty == 0.0
        assert item.breakdown.identity_penalty == 0.0

        # Without a quality profile there is no file-size sub-score; age and
        # tag_bonus have no component in the unified formula.
        assert item.breakdown.size == 0.0
        assert item.breakdown.age == 0.0
        assert item.breakdown.tag_bonus == 0.0
      end
    end

    test "respects preferred_qualities for sorting" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["720p", "1080p"])

      # 720p should come first even if 1080p has higher base score
      first_quality = ranked |> List.first() |> then(& &1.result.quality.resolution)
      assert first_quality == "720p"
    end

    test "1080p preferred sorts before higher-scoring 2160p" do
      # Simulate the user's scenario: 2160p has higher raw score but user prefers 1080p
      results = [
        build_result(%{
          title: "Movie.2023.2160p.BluRay.HDR.x265-HighScore",
          size: 4 * 1024 * 1024 * 1024,
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.2160p.BluRay.HDR.x265")
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-LowerScore",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 50,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      # Without preference - 2160p should win due to higher quality base score
      ranked_no_pref = ReleaseRanker.rank_all(results)
      first_no_pref = ranked_no_pref |> List.first() |> then(& &1.result.quality.resolution)
      assert first_no_pref == "2160p", "Without preference, 2160p should rank first"

      # With 1080p preference - 1080p should win despite lower raw score
      ranked_with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      first_with_pref = ranked_with_pref |> List.first() |> then(& &1.result.quality.resolution)
      assert first_with_pref == "1080p", "With 1080p preference, 1080p should rank first"

      # 2160p should be sorted to the end
      last_with_pref = ranked_with_pref |> List.last() |> then(& &1.result.quality.resolution)
      assert last_with_pref == "2160p"
    end

    test "non-preferred resolutions get index 999 for sorting" do
      results = [
        build_result(%{
          title: "Movie.2160p.BluRay",
          seeders: 100,
          quality: QualityParser.parse("Movie.2160p.BluRay")
        }),
        build_result(%{
          title: "Movie.720p.BluRay",
          seeders: 10,
          quality: QualityParser.parse("Movie.720p.BluRay")
        }),
        build_result(%{
          title: "Movie.1080p.BluRay",
          seeders: 50,
          quality: QualityParser.parse("Movie.1080p.BluRay")
        })
      ]

      # Only 1080p is preferred
      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])

      # 1080p should be first, then the rest sorted by score
      resolutions = Enum.map(ranked, & &1.result.quality.resolution)
      assert hd(resolutions) == "1080p"

      # Non-preferred (2160p and 720p) should come after all preferred
      non_preferred = tl(resolutions)
      assert "1080p" not in non_preferred
    end

    test "tag bonus is not used in unified scoring" do
      # Note: preferred_tags option is no longer supported.
      # Unified scoring uses quality_profile, seeder_score, and title_bonus.
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

      ranked = ReleaseRanker.rank_all(results)

      # Tag bonus is always 0 in unified scoring
      for item <- ranked do
        assert item.breakdown.tag_bonus == 0.0
      end
    end

    test "returns empty list for empty input" do
      assert ReleaseRanker.rank_all([]) == []
    end
  end

  # Tests for filter_acceptable/2

  describe "filter_acceptable/2 (hard removals only)" do
    test "does NOT remove low-seeder results (soft penalty now)" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 100)

      # min_seeders no longer hard-filters; all results survive filter_acceptable
      assert length(filtered) == 5
    end

    test "does NOT remove out-of-range sizes (soft penalty now)" do
      results = build_results()

      # Even with a tight size range, nothing is removed by filter_acceptable.
      filtered = ReleaseRanker.filter_acceptable(results, size_range: {2000, 10_000})

      assert length(filtered) == 5
    end

    test "removes results containing blocked tags" do
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

    test "only blocked tags remove; seeders/size pass through" do
      results = build_results()

      filtered =
        ReleaseRanker.filter_acceptable(results,
          min_seeders: 100,
          size_range: {2000, 10_000},
          blocked_tags: ["CAM"]
        )

      # Only the CAM release is removed; the rest survive despite seeders/size.
      refute Enum.any?(filtered, &String.contains?(&1.title, "CAM"))
      assert length(filtered) == 4
    end

    test "never returns empty purely from a high min_seeders" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 10_000)

      assert length(filtered) == 5
    end

    test "returns all when no filters specified" do
      results = build_results()

      # With min_seeders: 0 to disable default
      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0)

      assert length(filtered) == length(results)
    end
  end

  # NZB min-post-age filter (#120)

  describe "filter_acceptable/2 min_post_age_minutes (NZB-only)" do
    defp build_nzb(usenet_date) do
      %SearchResult{
        title: "Show.S01E01.1080p.WEB-DL",
        size: 1_073_741_824,
        seeders: nil,
        leechers: nil,
        download_url: "http://example.com/release.nzb",
        indexer: "TestIndexer",
        download_protocol: :nzb,
        usenet_date: usenet_date,
        nzb_grabs: 42
      }
    end

    defp build_torrent(opts \\ []) do
      %SearchResult{
        title: Keyword.get(opts, :title, "Torrent.Release.1080p"),
        size: 1_073_741_824,
        seeders: Keyword.get(opts, :seeders, 50),
        leechers: 5,
        download_url: "magnet:?xt=urn:btih:abc",
        indexer: "TestIndexer",
        download_protocol: :torrent,
        published_at: DateTime.utc_now()
      }
    end

    test "filters NZB results posted within min_post_age_minutes" do
      now = ~U[2024-11-25 12:00:00Z]
      too_recent = ~U[2024-11-25 11:55:00Z]
      old_enough = ~U[2024-11-25 11:00:00Z]

      results = [build_nzb(too_recent), build_nzb(old_enough)]

      filtered = ReleaseRanker.filter_acceptable(results, min_post_age_minutes: 30, now: now)

      assert length(filtered) == 1
      assert hd(filtered).usenet_date == old_enough
    end

    test "keeps NZB result posted exactly at the cutoff (strict comparison)" do
      now = ~U[2024-11-25 12:00:00Z]
      exact_cutoff = ~U[2024-11-25 11:30:00Z]

      results = [build_nzb(exact_cutoff)]

      filtered = ReleaseRanker.filter_acceptable(results, min_post_age_minutes: 30, now: now)
      assert length(filtered) == 1
    end

    test "passes through NZB results with no usenet_date (fail-open)" do
      results = [build_nzb(nil)]

      filtered =
        ReleaseRanker.filter_acceptable(results,
          min_post_age_minutes: 30,
          now: DateTime.utc_now()
        )

      assert length(filtered) == 1
    end

    test "min_post_age_minutes = nil disables the filter even for fresh NZBs" do
      now = ~U[2024-11-25 12:00:00Z]
      very_fresh = ~U[2024-11-25 11:59:00Z]

      results = [build_nzb(very_fresh)]
      filtered = ReleaseRanker.filter_acceptable(results, min_post_age_minutes: nil, now: now)
      assert length(filtered) == 1
    end

    test "does not filter torrent results regardless of age" do
      now = ~U[2024-11-25 12:00:00Z]

      results = [build_torrent(), build_torrent(title: "Another.1080p")]

      filtered = ReleaseRanker.filter_acceptable(results, min_post_age_minutes: 30, now: now)
      # Both torrents pass through.
      assert length(filtered) == 2
    end

    test "leaves NZB results without seeders unaffected by min_seeders" do
      # Regression guard: min_seeders applies only to torrents now.
      results = [build_nzb(nil)]

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 10)

      assert length(filtered) == 1
    end
  end

  # Tests for scoring functions (via breakdown)

  describe "quality scoring" do
    test "higher quality gets higher scores with quality_profile" do
      # With quality_profile, the SearchScorer uses QualityProfile.score_media_file
      profile =
        build_quality_profile(%{
          quality_standards: %{
            preferred_resolutions: ["2160p"],
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"]
          }
        })

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

      ranked = ReleaseRanker.rank_all(results, quality_profile: profile)

      hq_result = Enum.find(ranked, &(&1.result.quality.resolution == "2160p"))
      lq_result = Enum.find(ranked, &(&1.result.quality.resolution == "720p"))

      # Higher resolution with profile should score higher
      assert hq_result.score > lq_result.score
    end

    test "without quality_profile, quality score is based on seeders" do
      # Without quality_profile, SearchScorer.score_quality returns seeders as score
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      # Quality score equals seeders when no profile is set
      assert List.first(ranked).breakdown.quality == 50.0
    end

    test "preferred qualities affect sorting, not scoring" do
      # In unified scoring, preferred_qualities is used for sorting, not score bonus
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

      # Without preference - sort by score only
      without_pref = ReleaseRanker.rank_all(results)

      # With preference for 1080p - 1080p should be first due to sorting
      with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      first_with_pref = List.first(with_pref)

      # 1080p should be sorted first due to preferred_qualities
      assert first_with_pref.result.quality.resolution == "1080p"

      # Scores remain the same (sorting doesn't affect score)
      score_1080p = Enum.find(without_pref, &(&1.result.quality.resolution == "1080p"))
      score_1080p_pref = Enum.find(with_pref, &(&1.result.quality.resolution == "1080p"))
      assert score_1080p.breakdown.quality == score_1080p_pref.breakdown.quality
    end

    # The following four tests document a deliberate divergence from the
    # retired Mydia.Settings.QualityMatcher. QualityMatcher.matches?/2 hard-
    # rejected a result with {:error, :quality_not_allowed}, {:error,
    # :quality_unknown}, or {:error, violation} when a resolution fell outside
    # the preferred_resolutions allow-list, quality was nil, or a min/max
    # resolution constraint was violated. ReleaseRanker never adopted any of
    # those gates: per filter_acceptable/2's moduledoc, only blocked tags and
    # too-recent NZBs are hard removals now — every quality dimension is a
    # ranking signal, not a filter, so a weak match sinks instead of
    # vanishing. These tests pin down that the results stay in the ranking
    # rather than asserting the old exclusion contract, which no longer holds.

    test "a resolution outside preferred_resolutions is not excluded (no quality_not_allowed rejection)" do
      profile =
        build_quality_profile(%{
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["ac3", "aac"],
            preferred_resolutions: ["1080p", "720p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            movie_min_size_mb: 2048,
            movie_max_size_mb: 15360
          }
        })

      result =
        build_result(%{
          title: "Test.Movie.2024.480p.WEB-DL.x264-GROUP",
          size: 1 * 1024 * 1024 * 1024,
          seeders: 20,
          leechers: 2,
          quality: QualityParser.parse("Test.Movie.2024.480p.WEB-DL.x264-GROUP")
        })

      ranked = ReleaseRanker.rank_all([result], quality_profile: profile)
      assert [%{result: ^result}] = ranked

      [scored] = ReleaseRanker.score_all_with_reasons([result], quality_profile: profile)
      assert scored.status == :accepted
    end

    test "nil quality does not exclude a result when a quality profile is set (no quality_unknown rejection)" do
      profile = build_quality_profile()
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result], quality_profile: profile)
      assert length(ranked) == 1
    end

    test "a min_resolution violation zeroes the quality component AND hard-rejects the release" do
      # This assertion was inverted deliberately. It used to assert that a
      # sub-floor release was merely down-scored, on the reasoning that soft
      # penalties let weak releases sink rather than vanish. In practice
      # nothing sits below them: there is no minimum score to grab, so the top
      # of an all-sub-floor list is still taken. That is how a 1080p-floor
      # profile grabbed a 360p XviD of Dark Matter S02E01. :min_resolution is
      # now a floor, matching :excluded_sources.
      profile =
        build_quality_profile(%{
          quality_standards: %{
            preferred_resolutions: ["1080p", "2160p"],
            min_resolution: "1080p",
            max_resolution: "2160p"
          }
        })

      result =
        build_result(%{
          title: "Test.Movie.2024.720p.BluRay.x265-GROUP",
          seeders: 100,
          quality: QualityParser.parse("Test.Movie.2024.720p.BluRay.x265-GROUP")
        })

      breakdown = ReleaseRanker.calculate_score_breakdown(result, quality_profile: profile)
      assert breakdown.quality == 0.0

      assert ReleaseRanker.rank_all([result], quality_profile: profile) == []

      # The operator's manual escape hatch still surfaces it.
      assert length(
               ReleaseRanker.rank_all([result],
                 quality_profile: profile,
                 apply_resolution_floor: false
               )
             ) == 1
    end

    test "max_resolution stays a scoring signal and does not hard-reject" do
      # Only the floor gates. Grabbing above the ceiling wastes disk but still
      # yields a watchable file, so it remains a penalty.
      profile =
        build_quality_profile(%{
          quality_standards: %{
            preferred_resolutions: ["720p"],
            min_resolution: "720p",
            max_resolution: "1080p"
          }
        })

      result =
        build_result(%{
          title: "Test.Movie.2024.2160p.BluRay.x265-GROUP",
          seeders: 100,
          quality: QualityParser.parse("Test.Movie.2024.2160p.BluRay.x265-GROUP")
        })

      assert length(ReleaseRanker.rank_all([result], quality_profile: profile)) == 1
    end

    test "a profile without quality_standards zeroes the quality component" do
      profile = build_quality_profile(%{quality_standards: nil})
      result = build_result(%{seeders: 50})

      breakdown = ReleaseRanker.calculate_score_breakdown(result, quality_profile: profile)
      assert breakdown.quality == 0.0
    end
  end

  describe "seeder scoring" do
    test "more seeders get higher scores" do
      results = [
        build_result(%{seeders: 10, leechers: 10, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 100, leechers: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, leechers: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      scores = Enum.map(ranked, & &1.breakdown.seeders)
      assert scores == Enum.sort(scores, :desc)
    end

    test "zero seeders get zero score" do
      result = build_result(%{seeders: 0, leechers: 10})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 0)

      assert List.first(ranked).breakdown.seeders == 0.0
    end

    test "seeder scoring has diminishing returns (logarithmic)" do
      # Unified scoring uses log10(seeders + 1) * 10
      results = [
        build_result(%{seeders: 100, leechers: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, leechers: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      score_100 = Enum.find(ranked, &(&1.result.seeders == 100)).breakdown.seeders
      score_1000 = Enum.find(ranked, &(&1.result.seeders == 1000)).breakdown.seeders

      # 10x seeders should not give 10x score (diminishing returns via log10)
      # log10(101) * 10 ≈ 20, log10(1001) * 10 ≈ 30
      assert score_1000 < score_100 * 2
    end

    test "seeder ratio does not affect unified scoring (only seeder count matters)" do
      # Unified scoring uses simple log10 formula without ratio multipliers
      results = [
        # More seeders but poor ratio
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.MoreSeeders.1080p.x264"
        }),
        # Fewer seeders but good ratio
        build_result(%{
          seeders: 60,
          leechers: 30,
          title: "Movie.FewerSeeders.1080p.x264"
        })
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 50)

      more_seeders =
        Enum.find(ranked, &String.contains?(&1.result.title, "MoreSeeders")).breakdown.seeders

      fewer_seeders =
        Enum.find(ranked, &String.contains?(&1.result.title, "FewerSeeders")).breakdown.seeders

      # In unified scoring, more seeders = higher seeder score (no ratio penalty)
      assert more_seeders > fewer_seeders
    end
  end

  describe "minimum ratio penalty (soft)" do
    test "does NOT remove poor-ratio torrents (penalizes instead)" do
      results = [
        # 10% ratio - penalized but kept
        build_result(%{seeders: 10, leechers: 90, title: "Movie.Bad.1080p.x264"}),
        # 20% ratio - kept, no penalty
        build_result(%{seeders: 20, leechers: 80, title: "Movie.Ok.1080p.x264"}),
        # 50% ratio - kept, no penalty
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Good.1080p.x264"})
      ]

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0, min_ratio: 0.15)

      # Nothing removed — ratio is a soft penalty now.
      assert length(filtered) == 3
    end

    test "poor-ratio release carries a seeder_penalty in the breakdown" do
      results = [
        build_result(%{seeders: 10, leechers: 90, title: "Movie.Bad.1080p.x264"}),
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Good.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 0, min_ratio: 0.15)

      bad = Enum.find(ranked, &String.contains?(&1.result.title, "Bad"))
      good = Enum.find(ranked, &String.contains?(&1.result.title, "Good"))

      assert bad.breakdown.seeder_penalty < 0.0
      assert good.breakdown.seeder_penalty == 0.0
    end

    test "nil min_ratio applies no ratio penalty" do
      results = [
        build_result(%{seeders: 1, leechers: 99, title: "Movie.VeryBad.1080p.x264"}),
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Good.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 0, min_ratio: nil)

      assert length(ranked) == 2
      # With no min_ratio, only the seeder-minimum check can penalize; min_seeders
      # is 0 so both pass with no penalty.
      assert Enum.all?(ranked, &(&1.breakdown.seeder_penalty == 0.0))
    end

    test "healthy swarm still wins via select_best_result with min_ratio" do
      results = [
        # High seeders but poor ratio (17%) — penalized
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.2023.1080p.Popular.But.Stalled"
        }),
        # Fewer seeders but good ratio (67%)
        build_result(%{seeders: 60, leechers: 30, title: "Movie.2023.1080p.Healthy"})
      ]

      best = ReleaseRanker.select_best_result(results, min_seeders: 50, min_ratio: 0.20)

      # Both are kept; the stalled one is still selectable but the healthy swarm
      # should win on combined score given the ratio penalty.
      assert best != nil
    end

    test "torrents with zero peers receive no ratio penalty" do
      results = [
        build_result(%{seeders: 0, leechers: 0, title: "Movie.New.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 0, min_ratio: 0.15)

      assert length(ranked) == 1
      # Zero-peer torrents can't have a ratio computed, so no ratio penalty.
      # (min_seeders is 0, so no seeder-minimum penalty either.)
      assert List.first(ranked).breakdown.seeder_penalty == 0.0
    end
  end

  describe "soft size/seeder penalties (U2)" do
    test "AE2: an episode below the minimum size is kept with a size penalty" do
      # ~22 minute 1080p episode at 350 MB, below a 512 MB minimum.
      small =
        build_result(%{
          title: "Show.S09E01.1080p.WEB.h264-GROUP",
          size: 350 * 1024 * 1024,
          seeders: 20,
          quality: QualityParser.parse("Show.S09E01.1080p.WEB.h264-GROUP")
        })

      ranked = ReleaseRanker.rank_all([small], size_range: {512, 4096}, min_seeders: 0)

      assert length(ranked) == 1
      item = List.first(ranked)
      assert item.breakdown.size_penalty < 0.0
    end

    test "a release far outside the range is penalized more than one just outside" do
      just_below =
        build_result(%{
          title: "Show.S01E01.1080p.WEB.JustBelow",
          size: 480 * 1024 * 1024,
          seeders: 20
        })

      far_below =
        build_result(%{
          title: "Show.S01E01.1080p.WEB.FarBelow",
          size: 50 * 1024 * 1024,
          seeders: 20
        })

      in_range =
        build_result(%{
          title: "Show.S01E01.1080p.WEB.InRange",
          size: 1000 * 1024 * 1024,
          seeders: 20
        })

      ranked =
        ReleaseRanker.rank_all([just_below, far_below, in_range],
          size_range: {512, 4096},
          min_seeders: 0
        )

      a = Enum.find(ranked, &String.contains?(&1.result.title, "JustBelow"))
      b = Enum.find(ranked, &String.contains?(&1.result.title, "FarBelow"))
      c = Enum.find(ranked, &String.contains?(&1.result.title, "InRange"))

      assert c.breakdown.size_penalty == 0.0
      assert b.breakdown.size_penalty < a.breakdown.size_penalty
      assert a.breakdown.size_penalty < 0.0
    end

    test "a zero-seeder torrent stays in results with a reduced score" do
      results = [
        build_result(%{title: "Dead.1080p.x264", seeders: 0, leechers: 0}),
        build_result(%{title: "Alive.1080p.x264", seeders: 100})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 10)

      assert length(ranked) == 2
      dead = Enum.find(ranked, &String.contains?(&1.result.title, "Dead"))
      assert dead.breakdown.seeder_penalty < 0.0
    end

    test "NZB results (nil seeders) receive no seeder penalty" do
      nzb = build_nzb_result(%{nzb_completion: 1.0, title: "Show.S01E01.1080p.WEB-DL"})

      ranked = ReleaseRanker.rank_all([nzb], min_seeders: 10, min_ratio: 0.5)

      assert List.first(ranked).breakdown.seeder_penalty == 0.0
    end

    test "AE3: a blocked-tag release is absent from rank_all output" do
      results = [
        build_result(%{title: "Movie.CAM.1080p.x264", seeders: 100}),
        build_result(%{title: "Movie.1080p.BluRay.x264", seeders: 50})
      ]

      ranked = ReleaseRanker.rank_all(results, blocked_tags: ["CAM"], min_seeders: 0)

      titles = Enum.map(ranked, & &1.result.title)
      refute "Movie.CAM.1080p.x264" in titles
      assert "Movie.1080p.BluRay.x264" in titles
    end

    test "an invalid release (exe) is absent from output" do
      results = [
        build_result(%{title: "Movie.1080p.WEB.h264-GROUP.exe", seeders: 500}),
        build_result(%{title: "Movie.1080p.WEB.h264-GROUP.mkv", seeders: 5})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 0)

      titles = Enum.map(ranked, & &1.result.title)
      refute "Movie.1080p.WEB.h264-GROUP.exe" in titles
    end

    test "the NZB post-age safeguard still removes too-recent NZB results" do
      now = ~U[2024-11-25 12:00:00Z]
      too_recent = ~U[2024-11-25 11:55:00Z]

      nzb =
        build_nzb_result(%{
          nzb_completion: 1.0,
          usenet_date: too_recent,
          title: "Show.S01E01.1080p.WEB-DL"
        })

      ranked = ReleaseRanker.rank_all([nzb], min_post_age_minutes: 30, now: now)

      assert ranked == []
    end

    test "size penalty never flips a correct large release below a junk small one" do
      # A correct large in-range release vs a small out-of-range one: quality
      # still drives the order, the size penalty is too modest to flip them.
      profile = build_quality_profile()
      gb = 1024 * 1024 * 1024

      large =
        build_result(%{
          title: "Show.S01E01.1080p.BluRay.x264-GOOD",
          size: round(3.0 * gb),
          seeders: 50,
          quality: QualityParser.parse("Show.S01E01.1080p.BluRay.x264-GOOD")
        })

      tiny =
        build_result(%{
          title: "Show.S01E01.1080p.BluRay.x264-TINY",
          size: 50 * 1024 * 1024,
          seeders: 50,
          quality: QualityParser.parse("Show.S01E01.1080p.BluRay.x264-TINY")
        })

      ranked =
        ReleaseRanker.rank_all([tiny, large],
          quality_profile: profile,
          media_type: :episode,
          size_range: {512, 4096},
          min_seeders: 0
        )

      assert List.first(ranked).result.title == "Show.S01E01.1080p.BluRay.x264-GOOD"
    end
  end

  describe "size and age scoring" do
    # Note: Unified scoring does NOT use size or age in the score calculation.
    # These fields always return 0.0 in the breakdown.

    test "size score is always zero in unified scoring" do
      results = [
        build_result(%{size: 50 * 1024 * 1024, title: "Small"}),
        build_result(%{size: 5 * 1024 * 1024 * 1024, title: "Good"}),
        build_result(%{size: 30 * 1024 * 1024 * 1024, title: "Huge"})
      ]

      # Allow all sizes for comparison
      opts = [min_seeders: 0, size_range: {0, 100_000}]
      ranked = ReleaseRanker.rank_all(results, opts)

      # All size scores should be 0.0
      for item <- ranked do
        assert item.breakdown.size == 0.0
      end
    end

    test "age score is always zero in unified scoring" do
      now = DateTime.utc_now()

      results = [
        build_result(%{
          published_at: DateTime.add(now, -2, :day),
          title: "Recent"
        }),
        build_result(%{
          published_at: DateTime.add(now, -365, :day),
          title: "Old"
        }),
        build_result(%{
          published_at: nil,
          title: "NoDate"
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      # All age scores should be 0.0
      for item <- ranked do
        assert item.breakdown.age == 0.0
      end
    end
  end

  describe "tag scoring" do
    # Note: Unified scoring does NOT use tag_bonus. The tag_bonus field
    # always returns 0.0 in the breakdown.

    test "tag bonus is always zero in unified scoring" do
      results = [
        build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      ranked = ReleaseRanker.rank_all(results)

      # All tag_bonus scores should be 0.0
      for item <- ranked do
        assert item.breakdown.tag_bonus == 0.0
      end
    end
  end

  describe "score breakdown display (U1)" do
    test "title_match is the raw 0-10 bonus, not inflated ×100" do
      profile = build_quality_profile()

      result =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL.x264",
          seeders: 30,
          quality: QualityParser.parse("The.Studio.2025.S01E01.1080p.WEB-DL.x264")
        })

      ranked =
        ReleaseRanker.rank_all([result],
          quality_profile: profile,
          media_type: :episode,
          search_query: "The Studio S01E01",
          min_seeders: 0
        )

      title_match = List.first(ranked).breakdown.title_match

      assert title_match > 0.0

      assert title_match <= 10.0,
             "title_match should be in the raw 0-10 range, got #{title_match}"
    end

    test "size carries the real file-size sub-score when a profile is set" do
      profile = build_quality_profile()

      result =
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })

      ranked =
        ReleaseRanker.rank_all([result],
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 0
        )

      # Real contribution surfaced, not hardcoded 0.0
      assert List.first(ranked).breakdown.size > 0.0
    end

    test "penalty fields default to 0.0 and total still equals the documented sum" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result]) |> List.first()
      breakdown = ranked.breakdown

      assert breakdown.size_penalty == 0.0
      assert breakdown.seeder_penalty == 0.0
      assert breakdown.identity_penalty == 0.0

      # total = base components + penalties (all zero here), and the ranked
      # result's score mirrors the breakdown total.
      assert breakdown.total == ranked.score
    end

    test "ScoreBreakdown.new/1 raises when a required base field is omitted" do
      assert_raise ArgumentError, fn ->
        Mydia.Indexers.Structs.ScoreBreakdown.new(%{
          quality: 1.0,
          seeders: 1.0,
          size: 1.0,
          age: 1.0,
          title_match: 1.0,
          tag_bonus: 1.0
          # :total intentionally omitted (enforced key)
        })
      end
    end

    test "removing the ×100 inflation does not cross the zero-title-match threshold" do
      # A release with a real title match keeps title_match > 0.0 (just not ×100),
      # so reject_zero_title_match still keeps it.
      result =
        build_result(%{
          title: "The.Matrix.1999.1080p.BluRay.x264-Group",
          seeders: 50,
          quality: QualityParser.parse("The.Matrix.1999.1080p.BluRay.x264-Group")
        })

      ranked =
        ReleaseRanker.rank_all([result], search_query: "The Matrix 1999", min_seeders: 0)

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.title_match > 0.0
    end
  end

  describe "edge cases" do
    test "handles results with missing quality gracefully" do
      # Without quality_profile, quality score equals seeders
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      # Quality score = seeders when no quality_profile is set
      assert List.first(ranked).breakdown.quality == 50.0
    end

    test "handles results with missing published_at gracefully" do
      result = build_result(%{published_at: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      # Age is not used in unified scoring
      assert List.first(ranked).breakdown.age == 0.0
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
      assert Float.round(breakdown.title_match, 2) == breakdown.title_match
      assert Float.round(breakdown.tag_bonus, 2) == breakdown.tag_bonus
      assert Float.round(breakdown.total, 2) == breakdown.total
    end

    test "total score follows unified scoring formula" do
      # Unified scoring: (quality_score * 0.6 + seeder_score + title_bonus) * penalty
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # For this result:
      # - quality_score = 50 (equals seeders when no profile)
      # - seeder_score = log10(51) * 10 ≈ 17.1
      # - title_bonus = 0 (no search_query)
      # - zero_seeder_penalty = 1.0 (seeders > 0)
      # Expected total ≈ (50 * 0.6 + 17.1 + 0) * 1.0 ≈ 47.1
      assert breakdown.total > 40
      assert breakdown.total < 60
    end
  end

  describe "title matching" do
    test "exact title match gets higher score than partial match" do
      # Simulates: searching for "The Studio S01E01"
      exact_match =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL.x264",
          seeders: 30
        })

      partial_match =
        build_result(%{
          title: "Marvel.Studios.Assembled.S01E01.1080p.HEVC.x265",
          seeders: 30
        })

      # With search_query, exact match should rank higher
      ranked =
        ReleaseRanker.rank_all([exact_match, partial_match],
          search_query: "The Studio S01E01",
          media_type: :episode,
          min_seeders: 1
        )

      # The exact match should be first
      assert List.first(ranked).result.title =~ "The.Studio"

      # And should have a higher title_match score
      exact_breakdown = Enum.find(ranked, &(&1.result.title =~ "The.Studio")).breakdown
      partial_breakdown = Enum.find(ranked, &(&1.result.title =~ "Marvel")).breakdown

      assert exact_breakdown.title_match > partial_breakdown.title_match
    end

    test "without search_query, title_match defaults to zero" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 1)
      breakdown = List.first(ranked).breakdown

      # Without search_query, title_match is 0 (no bonus applied)
      assert breakdown.title_match == 0.0
    end

    test "title matching with search query returns positive score" do
      result =
        build_result(%{
          title: "The.Studio.S01E01.1080p.BluRay.x264.DTS",
          seeders: 50
        })

      ranked =
        ReleaseRanker.rank_all([result],
          search_query: "The Studio S01E01",
          media_type: :episode,
          min_seeders: 1
        )

      breakdown = List.first(ranked).breakdown

      # With matching search_query, title_match should be positive
      assert breakdown.title_match > 0
    end

    test "title matching handles year in query" do
      result =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL",
          seeders: 50
        })

      ranked =
        ReleaseRanker.rank_all([result],
          search_query: "The Studio 2025 S01E01",
          media_type: :episode,
          min_seeders: 1
        )

      breakdown = List.first(ranked).breakdown

      # Should have positive title match with year included
      assert breakdown.title_match > 0
    end

    test "exact series title ranks higher than similar series with same seeders" do
      # Real-world case: searching for "The Girlfriend S01"
      # With the same seeders, title matching should differentiate the results
      mb = 1024 * 1024
      gb = 1024 * mb

      # Use same seeders to isolate title matching effect
      seeders = 50

      results = [
        # Unrelated documentary series with similar words
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: seeders
        }),
        # The actual series we want
        build_result(%{
          title: "The.Girlfriend.S01E01-06.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 8 * gb,
          seeders: seeders
        }),
        # Different series with similar name
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: seeders
        }),
        # The actual series (season pack with 2025)
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.10bit.WEBRip.6CH.x265.HEVC.PSA",
          size: 4 * gb,
          seeders: seeders
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          media_type: :episode,
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # The actual "The Girlfriend" series should have higher title_match than related series
      actual_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "The.Girlfriend.2025"))

      experience_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "Experience"))

      untold_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "Untold"))

      # The actual series should have higher title_match score
      assert actual_series.breakdown.title_match >= experience_series.breakdown.title_match,
             """
             Actual series should have higher title_match than "The Girlfriend Experience".
             Actual: #{actual_series.breakdown.title_match}
             Experience: #{experience_series.breakdown.title_match}
             """

      assert actual_series.breakdown.title_match >= untold_series.breakdown.title_match,
             """
             Actual series should have higher title_match than "Untold: The Girlfriend Who Didn't Exist".
             Actual: #{actual_series.breakdown.title_match}
             Untold: #{untold_series.breakdown.title_match}
             """
    end

    test "without search_query, title_match is zero for all results" do
      # Without search_query, title relevance is not scored
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: 3
        }),
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.WEBRip.x265-KONTRAST",
          size: 7 * gb,
          seeders: 36
        }),
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        })
      ]

      # Without search_query, all results get title_match score of 0
      ranked_without_query =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # All title_match scores should be 0 (no query provided)
      assert Enum.all?(ranked_without_query, fn r -> r.breakdown.title_match == 0.0 end),
             "Without search_query, title_match should be 0"

      # With search_query, title_match scores are calculated
      ranked_with_query =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          media_type: :episode,
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # With query, at least some results should have positive title_match
      assert Enum.any?(ranked_with_query, fn r -> r.breakdown.title_match > 0 end),
             "With search_query, at least some results should have positive title_match"
    end
  end

  describe "zero title match rejection" do
    test "rejects TV show episode when searching for a movie with same words in title" do
      # Real-world bug: searching for movie "Casino Royale 2006" returned
      # "Secret Life of the Auction House S01E08 Casino Royale Sweet Shop"
      # because it scored 48.9 total (quality: 69.8, seeders: 7.0) despite
      # having title_match of 0.0 - the words "Casino Royale" appear in the
      # TV episode title but the overall title doesn't match the search query.
      gb = 1024 * 1024 * 1024

      results = [
        # The wrong release - TV show episode that happens to contain search words
        build_result(%{
          title:
            "Secret Life of the Auction House S01E08 Casino Royale Sweet Shop 1080p AMZN WEB-DL DDP2 0 H 264-RAWR",
          size: round(2.5 * gb),
          seeders: 7,
          quality:
            QualityParser.parse(
              "Secret Life of the Auction House S01E08 Casino Royale Sweet Shop 1080p AMZN WEB-DL DDP2 0 H 264-RAWR"
            )
        }),
        # A correct match for Casino Royale
        build_result(%{
          title: "Casino.Royale.2006.1080p.BluRay.x264-Group",
          size: round(10.0 * gb),
          seeders: 50,
          quality: QualityParser.parse("Casino.Royale.2006.1080p.BluRay.x264-Group")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Casino Royale 2006",
          preferred_qualities: ["1080p"],
          min_seeders: 0
        )

      # The TV show episode should be filtered out (title_match is 0.0)
      tv_episode =
        Enum.find(ranked, &String.contains?(&1.result.title, "Secret Life of the Auction House"))

      assert tv_episode == nil,
             "TV show episode with 0 title match should be filtered out when search_query is provided"

      # The correct movie should be selected
      best = List.first(ranked)
      assert best != nil
      assert String.contains?(best.result.title, "Casino.Royale.2006")
    end

    test "rejects completely unrelated release when search_query is provided" do
      gb = 1024 * 1024 * 1024

      results = [
        build_result(%{
          title: "Completely.Unrelated.Movie.2023.1080p.BluRay.x264",
          size: round(8.0 * gb),
          seeders: 200,
          quality: QualityParser.parse("Completely.Unrelated.Movie.2023.1080p.BluRay.x264")
        })
      ]

      # When searching with a specific query, unrelated results should be filtered
      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Casino Royale 2006",
          min_seeders: 0
        )

      assert ranked == [],
             "Completely unrelated release should be filtered out when search_query is provided"
    end

    test "does not reject results when no search_query is provided" do
      # Without search_query, title matching is disabled - all results should pass
      results = [
        build_result(%{
          title: "Any.Movie.1080p.BluRay.x264",
          seeders: 50
        })
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 0)

      assert length(ranked) == 1,
             "Results should not be filtered by title when no search_query is provided"
    end

    test "only the TV episode is filtered when correct match also exists" do
      # When search_query is provided, only results with 0 title match are rejected
      gb = 1024 * 1024 * 1024

      results = [
        # Wrong release - unrelated content
        build_result(%{
          title: "Some.Random.Show.S01E01.1080p.WEB-DL",
          size: round(3.0 * gb),
          seeders: 100,
          quality: QualityParser.parse("Some.Random.Show.S01E01.1080p.WEB-DL")
        }),
        # Correct match
        build_result(%{
          title: "The.Matrix.1999.1080p.BluRay.x264-Group",
          size: round(10.0 * gb),
          seeders: 50,
          quality: QualityParser.parse("The.Matrix.1999.1080p.BluRay.x264-Group")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "The Matrix 1999",
          min_seeders: 0
        )

      # Only the matching result should remain
      assert length(ranked) == 1
      assert String.contains?(List.first(ranked).result.title, "The.Matrix")
    end
  end

  describe "TV release penalty for movie searches (soft)" do
    test "penalizes (does not remove) a TV season release in a movie search" do
      # Real-world bug: searching for movie "Frozen 2013" matched
      # "Frozen Planet II S01" because the word "Frozen" overlapped. The TV
      # release is now kept but softly penalized as an identity mismatch, so the
      # real movie still wins.
      gb = 1024 * 1024 * 1024

      results = [
        build_result(%{
          title: "Frozen Planet II S01 1080p BluRay x265",
          size: round(15.0 * gb),
          seeders: 50,
          quality: QualityParser.parse("Frozen Planet II S01 1080p BluRay x265")
        }),
        build_result(%{
          title: "Frozen.2013.1080p.BluRay.x264-Group",
          size: round(8.0 * gb),
          seeders: 30,
          quality: QualityParser.parse("Frozen.2013.1080p.BluRay.x264-Group")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Frozen 2013",
          media_type: :movie,
          min_seeders: 0
        )

      tv_release = Enum.find(ranked, &String.contains?(&1.result.title, "Frozen Planet II"))
      movie = Enum.find(ranked, &String.contains?(&1.result.title, "Frozen.2013"))

      # The TV release is kept but penalized; the movie wins on score.
      assert tv_release != nil
      assert tv_release.breakdown.identity_penalty < 0.0
      assert movie.breakdown.identity_penalty == 0.0
      assert String.contains?(List.first(ranked).result.title, "Frozen.2013")
    end

    test "penalizes a release with an S01E05 episode pattern in a movie search" do
      gb = 1024 * 1024 * 1024

      results = [
        build_result(%{
          title: "Breaking Bad S01E05 1080p BluRay x265",
          size: round(2.0 * gb),
          seeders: 100,
          quality: QualityParser.parse("Breaking Bad S01E05 1080p BluRay x265")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Breaking Bad 2008",
          media_type: :movie,
          min_seeders: 0
        )

      # Kept (soft), but penalized as an identity mismatch.
      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty < 0.0
    end

    test "does not reject TV releases when media_type is :episode" do
      gb = 1024 * 1024 * 1024

      results = [
        build_result(%{
          title: "Breaking Bad S01E05 1080p BluRay x265",
          size: round(2.0 * gb),
          seeders: 100,
          quality: QualityParser.parse("Breaking Bad S01E05 1080p BluRay x265")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Breaking Bad S01E05",
          media_type: :episode,
          min_seeders: 0
        )

      assert length(ranked) == 1,
             "TV episode should not be filtered when media_type is :episode"
    end

    test "does not reject TV releases when media_type is not specified" do
      gb = 1024 * 1024 * 1024

      results = [
        build_result(%{
          title: "Some.Show.S02E10.1080p.WEB-DL",
          size: round(2.0 * gb),
          seeders: 50,
          quality: QualityParser.parse("Some.Show.S02E10.1080p.WEB-DL")
        })
      ]

      # No media_type specified, so TV releases should NOT be filtered
      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "Some Show",
          min_seeders: 0
        )

      assert length(ranked) == 1,
             "Without media_type, TV releases should not be filtered"
    end
  end

  describe "episode/season identity penalty (U3)" do
    test "AE1: legit S09E01 releases rank above an identity-less parody, parody last but present" do
      # The reported Rick and Morty bug: the parody has no season/episode
      # identity, so it must sink below every real S09E01 release while staying
      # selectable at the bottom.
      results = [
        build_result(%{
          title: "Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP",
          seeders: 5,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP")
        }),
        build_result(%{
          title: "Rick.and.Morty.S09E01.720p.WEB.h264-OTHER",
          seeders: 20,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.720p.WEB.h264-OTHER")
        }),
        build_result(%{
          title: "Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p",
          seeders: 500,
          quality: QualityParser.parse("Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        )

      titles = Enum.map(ranked, & &1.result.title)

      # Parody is present...
      assert "Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p" in titles
      # ...but last, behind both real S09E01 releases.
      assert List.last(ranked).result.title ==
               "Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p"

      parody = List.last(ranked)
      assert parody.breakdown.identity_penalty < 0.0

      real_matches =
        Enum.reject(ranked, &String.contains?(&1.result.title, "Parody"))

      assert Enum.all?(real_matches, &(&1.breakdown.identity_penalty == 0.0))
      assert Enum.all?(real_matches, &(&1.score > parody.score))
    end

    test "AE4: a wrong-episode release is kept (penalized) and selectable" do
      results = [
        build_result(%{
          title: "Rick.and.Morty.S09E02.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E02.1080p.WEB.h264-GROUP")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        )

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty < 0.0
    end

    test "a parseable title with no episode identity is penalized" do
      results = [
        build_result(%{
          title: "Rick.and.Morty.Complete.Collection.1080p.WEB",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.Complete.Collection.1080p.WEB")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        )

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty < 0.0
    end

    test "fail-open: an unparseable title gets no identity penalty even with expected_episode" do
      # No expected_title supplied, so no prior parse ran; the identity stage
      # must parse and, finding nothing, fail open.
      results = [
        build_result(%{
          title: "1080p.x264.AAC",
          seeders: 10,
          quality: nil
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        )

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty == 0.0
    end

    test "season search: a correct-season pack matches; a wrong-season pack is penalized" do
      correct =
        build_result(%{
          title: "Rick.and.Morty.S09.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09.1080p.WEB.h264-GROUP")
        })

      wrong =
        build_result(%{
          title: "Rick.and.Morty.S08.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S08.1080p.WEB.h264-GROUP")
        })

      ranked =
        ReleaseRanker.rank_all([correct, wrong],
          media_type: :episode,
          expected_season: 9,
          min_seeders: 0
        )

      correct_ranked = Enum.find(ranked, &String.contains?(&1.result.title, "S09"))
      wrong_ranked = Enum.find(ranked, &String.contains?(&1.result.title, "S08"))

      assert correct_ranked.breakdown.identity_penalty == 0.0
      assert wrong_ranked.breakdown.identity_penalty < 0.0
    end

    test "AE4: an episode search with only season packs returns a selectable penalized pack" do
      results = [
        build_result(%{
          title: "Rick.and.Morty.S09.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09.1080p.WEB.h264-GROUP")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        )

      # Season pack matches season but lacks the episode → penalized, not removed.
      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty < 0.0
    end

    test "movie search: a TV-pattern release is penalized as an identity mismatch" do
      results = [
        build_result(%{
          title: "Frozen.Planet.II.S01.1080p.BluRay.x265",
          seeders: 50,
          quality: QualityParser.parse("Frozen.Planet.II.S01.1080p.BluRay.x265")
        }),
        build_result(%{
          title: "Frozen.2013.1080p.BluRay.x264-Group",
          seeders: 50,
          quality: QualityParser.parse("Frozen.2013.1080p.BluRay.x264-Group")
        })
      ]

      ranked = ReleaseRanker.rank_all(results, media_type: :movie, min_seeders: 0)

      tv = Enum.find(ranked, &String.contains?(&1.result.title, "Frozen.Planet"))
      movie = Enum.find(ranked, &String.contains?(&1.result.title, "Frozen.2013"))

      # TV-pattern release is kept now (soft), but penalized below the movie.
      assert tv != nil
      assert tv.breakdown.identity_penalty < 0.0
      assert movie.breakdown.identity_penalty == 0.0
      assert movie.score > tv.score
    end

    test "no expected identity (generic episode search): no identity penalty applied" do
      results = [
        build_result(%{
          title: "Some.Show.S02E10.1080p.WEB-DL",
          seeders: 50,
          quality: QualityParser.parse("Some.Show.S02E10.1080p.WEB-DL")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          search_query: "Some Show",
          min_seeders: 0
        )

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.identity_penalty == 0.0
    end
  end

  describe "real-world movie search scenarios" do
    @doc """
    Test case based on actual search results for "xXx 2002" movie with HD-1080p quality profile.

    This captures real-world scoring behavior to help identify issues with the ranking algorithm.
    The results show various 1080p releases with different codecs, sources, and file sizes.
    """
    test "xXx 2002 movie search - 1080p quality profile scoring" do
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # x265 BluRay - NZBFinder (Usenet, no seeders) - was scoring 83
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE",
          size: round(9.5 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE")
        }),
        # x264 BluRay with AC3 - NZBFinder (no seeders)
        build_result(%{
          title: "xXx 2002 1080p Bluray AC3 x264 - AdiT -",
          size: round(6.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p Bluray AC3 x264 - AdiT -")
        }),
        # x264 BluRay with DTS:X - NZBFinder (no seeders)
        build_result(%{
          title: "xXx 2002 1080p BluRay AC3 DTS x264-GAIA",
          size: round(15.1 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p BluRay AC3 DTS x264-GAIA")
        }),
        # x264 BluRay - BitSearch with 1 seeder
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x264-OFT",
          size: round(6.0 * gb),
          seeders: 1,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x264-OFT")
        }),
        # Remastered x265 - NZBFinder (no seeders)
        build_result(%{
          title: "xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman",
          size: round(5.5 * gb),
          seeders: 0,
          quality:
            QualityParser.parse("xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman")
        }),
        # 15th Anniversary Edition - BitSearch with 24 seeders (was scoring 75)
        build_result(%{
          title: "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed",
          size: round(11.0 * gb),
          seeders: 24,
          quality:
            QualityParser.parse(
              "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed"
            )
        }),
        # WEB-DL - BitSearch with 130 seeders
        build_result(%{
          title: "xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS",
          size: round(4.6 * gb),
          seeders: 130,
          leechers: 20,
          quality: QualityParser.parse("xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS")
        }),
        # WEB-DL H.264 DD+ - NZBFinder (no seeders)
        build_result(%{
          title: "xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS",
          size: round(14.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS")
        }),
        # DVDRip - NZBFinder (no seeders)
        build_result(%{
          title: "XXX.2002.DVDRip.x264-DJ",
          size: round(1.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.DVDRip.x264-DJ")
        }),
        # REMUX - NZBFinder (no seeders)
        build_result(%{
          title: "XXX.2002.BD-Remux.mkv",
          size: round(15.7 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.BD-Remux.mkv")
        }),
        # Nordic version with 32 seeders - BitSearch
        build_result(%{
          title: "xXx.2002.NORDiC.BRRip.x264-SWAXXON",
          size: round(698.7 * mb),
          seeders: 32,
          quality: QualityParser.parse("xXx.2002.NORDiC.BRRip.x264-SWAXXON")
        }),
        # Unrelated XXX content - should rank low due to title mismatch
        build_result(%{
          title: "[Private] The Private Gladiator 1 XXX (2002) (1080p HEVC) [GhostFreakXX]",
          size: round(1.5 * gb),
          seeders: 8,
          quality:
            QualityParser.parse(
              "[Private] The Private Gladiator 1 XXX (2002) (1080p HEVC) [GhostFreakXX]"
            )
        })
      ]

      # Rank with 1080p preferred quality and the search query
      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "xXx 2002",
          preferred_qualities: ["1080p"],
          min_seeders: 0,
          size_range: {100, 20_000}
        )

      # Display ranking for debugging
      ranking_info =
        ranked
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {r, idx} ->
          "  #{idx}. Score: #{Float.round(r.score, 1)} | Seeders: #{r.result.seeders} | #{r.result.title}\n" <>
            "     Quality: #{inspect(r.breakdown.quality)} | Seeders Score: #{inspect(r.breakdown.seeders)} | " <>
            "Size: #{inspect(r.breakdown.size)} | Title: #{inspect(r.breakdown.title_match)}"
        end)

      # Basic assertions for unified scoring

      # 1. Results should be sorted - first by preferred_qualities (1080p first), then by score
      assert ranked != [], "Expected some results after filtering"

      # 2. Unrelated "Private Gladiator" should rank lower due to title mismatch
      gladiator = Enum.find(ranked, &String.contains?(&1.result.title, "Private Gladiator"))
      xxx_result = Enum.find(ranked, &String.contains?(&1.result.title, "xXx.2002"))

      if gladiator && xxx_result do
        assert xxx_result.score > gladiator.score,
               """
               xXx result should score higher than unrelated "Private Gladiator" content.
               xXx score: #{xxx_result.score}
               Gladiator score: #{gladiator.score}

               Full ranking:
               #{ranking_info}
               """
      end

      # 3. Results with more seeders should generally score higher (all else equal)
      # The WEB-DL with 130 seeders should have one of the highest seeder scores
      webdl_130 =
        Enum.find(ranked, fn r ->
          r.result.seeders == 130 && String.contains?(r.result.title, "WEB-DL")
        end)

      if webdl_130 do
        assert webdl_130.breakdown.seeders > 20.0,
               """
               WEB-DL with 130 seeders should have high seeder score.
               Got: #{webdl_130.breakdown.seeders}
               """
      end
    end
  end

  describe "unified scoring mode" do
    test "always uses SearchScorer algorithm (with or without quality_profile)" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264",
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      profile = build_quality_profile()

      # With quality_profile
      ranked_with_profile =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 1
        )

      assert length(ranked_with_profile) == 1
      item = List.first(ranked_with_profile)

      # With a quality profile, `:size` surfaces the real file-size sub-score.
      # No size standards are configured here, so the unconstrained file-size
      # score is 100.0. Age has no component in the unified formula.
      assert item.breakdown.size == 100.0
      assert item.breakdown.age == 0.0
      assert item.score > 0

      # Without quality_profile - still uses unified scoring
      ranked_without_profile = ReleaseRanker.rank_all(results, min_seeders: 1)

      assert length(ranked_without_profile) == 1
      item_no_profile = List.first(ranked_without_profile)

      # Without a profile there is no file-size sub-score, so size stays 0.0.
      assert item_no_profile.breakdown.size == 0.0
      assert item_no_profile.breakdown.age == 0.0
    end

    test "penalizes zero-seeder results" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-Seeded",
          seeders: 50,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-Dead",
          seeders: 0,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      profile = build_quality_profile()

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 0
        )

      seeded = Enum.find(ranked, &String.contains?(&1.result.title, "Seeded"))
      dead = Enum.find(ranked, &String.contains?(&1.result.title, "Dead"))

      # Seeded result should score higher due to zero-seeder penalty
      assert seeded.score > dead.score
    end

    test "considers title relevance with search_query" do
      results = [
        build_result(%{
          title: "The.Girlfriend.2025.S01E01.1080p.WEB-DL",
          seeders: 50,
          quality: QualityParser.parse("The.Girlfriend.2025.S01E01.1080p.WEB-DL")
        }),
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01.1080p.WEB-DL",
          seeders: 50,
          quality: QualityParser.parse("The.Girlfriend.Experience.S01E01.1080p.WEB-DL")
        })
      ]

      profile = build_quality_profile()

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :episode,
          search_query: "The Girlfriend S01E01",
          min_seeders: 1
        )

      # The exact match should rank higher
      first_result = List.first(ranked)
      assert String.contains?(first_result.result.title, "The.Girlfriend.2025")
    end

    test "select_best_result uses unified scoring" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-BestMatch",
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.2023.1080p.WEB-DL.x264-LowerScore",
          seeders: 20,
          quality: QualityParser.parse("Movie.2023.1080p.WEB-DL.x264")
        })
      ]

      profile = build_quality_profile()

      best =
        ReleaseRanker.select_best_result(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 1
        )

      assert best != nil
      # Result with more seeders should win (both are 1080p BluRay/WEB-DL)
      assert String.contains?(best.result.title, "BestMatch")
    end
  end

  describe "title mismatch filtering" do
    @gb 1024 * 1024 * 1024

    test "rejects results where parsed title doesn't match expected title" do
      # Real-world bug: searching for "Fallout S01E04" returned
      # "Claws S01E04 Fallout 1080p..." because "Fallout" is the episode title,
      # not the show title. ReleaseParser extracts "Claws" as the show title.
      results = [
        build_result(%{
          title: "Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264-ViSUM",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Fallout",
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      assert ranked == [],
             "Result with parsed title 'Claws' should be rejected when expecting 'Fallout'"
    end

    test "accepts results where parsed title matches expected title" do
      results = [
        build_result(%{
          title: "Fallout.S01E04.1080p.AMZN.WEB-DL.DDP5.1.H.264-GROUP",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Fallout.S01E04.1080p.AMZN.WEB-DL.DDP5.1.H.264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Fallout",
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      assert length(ranked) == 1
    end

    test "accepts results with close title match" do
      results = [
        build_result(%{
          title: "Dr.Who.S14E01.720p.WEB-DL.x264-GROUP",
          size: round(2.0 * @gb),
          seeders: 100,
          quality: QualityParser.parse("Dr.Who.S14E01.720p.WEB-DL.x264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Doctor Who",
          media_type: :episode,
          search_query: "Doctor Who S14E01",
          min_seeders: 0
        )

      # "dr who" vs "doctor who" should be close enough to pass
      assert length(ranked) == 1
    end

    test "passes through release names with no extractable title (fail-open)" do
      # ReleaseParser returns no title for this input, so the title-mismatch
      # filter cannot compare and lets it through (fail-open). Note: ReleaseParser
      # is more capable than the old parser — gibberish that DOES yield a title
      # (e.g. "abc123def456") is now correctly extracted and filtered when it
      # differs from the expected title.
      # We omit search_query to avoid reject_zero_title_match catching it.
      results = [
        build_result(%{
          title: "1080p.x264.AAC",
          size: round(1.0 * @gb),
          seeders: 10,
          quality: nil
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Fallout",
          min_seeders: 0
        )

      assert length(ranked) == 1,
             "Releases with no extractable title should pass through (fail-open)"
    end

    test "skips filter when expected_title is empty string" do
      results = [
        build_result(%{
          title: "Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264-ViSUM",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "",
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      assert length(ranked) == 1,
             "Empty expected_title should bypass title mismatch filtering"
    end

    test "skips filter when expected_title is whitespace-only" do
      results = [
        build_result(%{
          title: "Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264-ViSUM",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "   ",
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      assert length(ranked) == 1,
             "Whitespace-only expected_title should bypass title mismatch filtering"
    end

    test "skips filter when expected_title is not provided" do
      results = [
        build_result(%{
          title: "Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264-ViSUM",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      # Without expected_title, the filter is skipped
      assert length(ranked) == 1,
             "Without expected_title, no title mismatch filtering should occur"
    end

    test "rejects movie title mismatches" do
      # Searching for "Inception" but indexer returns "Interstellar" (unrelated movie)
      results = [
        build_result(%{
          title: "Interstellar.2014.1080p.BluRay.x264-GROUP",
          size: round(8.0 * @gb),
          seeders: 100,
          quality: QualityParser.parse("Interstellar.2014.1080p.BluRay.x264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Inception",
          media_type: :movie,
          search_query: "Inception 2010",
          min_seeders: 0
        )

      assert ranked == [],
             "Movie with different parsed title should be rejected"
    end

    test "filters correct result among mixed results" do
      results = [
        build_result(%{
          title: "Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264-ViSUM",
          size: round(3.0 * @gb),
          seeders: 200,
          quality: QualityParser.parse("Claws S01E04 Fallout 1080p AMZN WEB-DL DDP 5.1 H 264")
        }),
        build_result(%{
          title: "Fallout.S01E04.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb",
          size: round(3.0 * @gb),
          seeders: 50,
          quality: QualityParser.parse("Fallout.S01E04.1080p.AMZN.WEB-DL.DDP5.1.H.264")
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          expected_title: "Fallout",
          media_type: :episode,
          search_query: "Fallout S01E04",
          min_seeders: 0
        )

      # Only the correct Fallout result should remain, even though Claws had more seeders
      assert length(ranked) == 1
      assert String.contains?(List.first(ranked).result.title, "Fallout.S01E04")
    end
  end

  # NZB-aware scoring branch (#121)

  describe "scoring branches by download_protocol" do
    defp build_nzb_result(attrs) do
      defaults = %{
        title: "Show.S01E01.1080p.WEB-DL",
        size: 1_073_741_824,
        seeders: nil,
        leechers: nil,
        download_url: "http://example.com/release.nzb",
        indexer: "TestIndexer",
        download_protocol: :nzb,
        quality: QualityParser.parse("Show.S01E01.1080p.WEB-DL"),
        published_at: DateTime.utc_now()
      }

      Map.merge(defaults, attrs) |> then(&struct!(SearchResult, &1))
    end

    test "NZB with high completion outranks NZB with low completion regardless of grabs" do
      high_completion =
        build_nzb_result(%{nzb_completion: 1.0, nzb_grabs: 5, title: "Show.S01E01.1080p.A"})

      low_completion =
        build_nzb_result(%{nzb_completion: 0.6, nzb_grabs: 500, title: "Show.S01E01.1080p.B"})

      ranked = ReleaseRanker.rank_all([low_completion, high_completion], min_seeders: 0)

      assert length(ranked) == 2
      assert hd(ranked).result.title == "Show.S01E01.1080p.A"
    end

    test "NZB with unknown completion defaults to 1.0 (does not penalize)" do
      unknown = build_nzb_result(%{nzb_completion: nil, nzb_grabs: nil, title: "Unknown.1080p"})
      half = build_nzb_result(%{nzb_completion: 0.5, nzb_grabs: nil, title: "Half.1080p"})

      ranked = ReleaseRanker.rank_all([half, unknown], min_seeders: 0)
      assert hd(ranked).result.title == "Unknown.1080p"
    end

    test "torrent scoring is unchanged (regression)" do
      # With no quality profile, seeder count dominates the score for torrents
      # (since quality_score also falls back to seeders when no profile is set).
      high_seeders =
        build_result(%{title: "Movie.1080p.HighSeed", seeders: 500, leechers: 5})

      low_seeders =
        build_result(%{title: "Movie.1080p.LowSeed", seeders: 5, leechers: 5})

      ranked = ReleaseRanker.rank_all([low_seeders, high_seeders], min_seeders: 0)
      assert hd(ranked).result.title == "Movie.1080p.HighSeed"
    end
  end

  describe "score_all_with_reasons/2 and build_filter_stats/2 (U7)" do
    test "never returns size/seeders/ratio rejection reasons; a too-small release is accepted with a size penalty" do
      results = [
        build_result(%{
          title: "Show.S01E01.1080p.WEB.h264-GROUP",
          size: 50 * 1024 * 1024,
          seeders: 0,
          leechers: 100
        })
      ]

      scored =
        ReleaseRanker.score_all_with_reasons(results,
          size_range: {512, 4096},
          min_seeders: 10,
          min_ratio: 0.5
        )

      row = List.first(scored)
      assert row.status == :accepted
      assert row.breakdown.size_penalty < 0.0
      assert row.breakdown.seeder_penalty < 0.0

      reasons = Enum.map(scored, & &1.rejection_reason)
      refute Enum.any?(reasons, &(&1 && String.contains?(&1, "size_out_of_range")))
      refute Enum.any?(reasons, &(&1 && String.contains?(&1, "low_seeders")))
      refute Enum.any?(reasons, &(&1 && String.contains?(&1, "low_ratio")))
    end

    test "a blocked-tag release is rejected with reason blocked_tag" do
      results = [build_result(%{title: "Movie.CAM.1080p.x264", seeders: 100})]

      scored = ReleaseRanker.score_all_with_reasons(results, blocked_tags: ["CAM"])

      row = List.first(scored)
      assert row.status == :rejected
      assert String.starts_with?(row.rejection_reason, "blocked_tag")
    end

    test "an invalid release is rejected as invalid" do
      results = [build_result(%{title: "Movie.1080p.WEB.h264-GROUP.exe", seeders: 500})]

      scored = ReleaseRanker.score_all_with_reasons(results)

      row = List.first(scored)
      assert row.status == :rejected
      assert String.starts_with?(row.rejection_reason, "invalid")
    end

    test "an identity-mismatched release is accepted carrying a non-zero identity penalty" do
      results = [
        build_result(%{
          title: "Rick.and.Morty.S09E02.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E02.1080p.WEB.h264-GROUP")
        })
      ]

      scored =
        ReleaseRanker.score_all_with_reasons(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1
        )

      row = List.first(scored)
      assert row.status == :accepted
      assert row.breakdown.identity_penalty < 0.0
    end

    test "build_filter_stats flags penalized-but-kept results and drops size rejections" do
      results = [
        build_result(%{
          title: "Show.S09E02.1080p.WEB.h264-GROUP",
          size: 50 * 1024 * 1024,
          seeders: 50,
          quality: QualityParser.parse("Show.S09E02.1080p.WEB.h264-GROUP")
        })
      ]

      stats =
        ReleaseRanker.build_filter_stats(results,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          size_range: {512, 4096}
        )

      row = List.first(stats["results"])
      assert row["status"] == "accepted"
      assert row["penalized"] == true
      assert row["penalties"]["identity_penalty"] < 0.0
      assert row["penalties"]["size_penalty"] < 0.0

      refute Map.has_key?(stats["rejection_counts"], "size_out_of_range")
    end
  end

  describe "custom formats" do
    defp compiled_format(name, patterns, opts) do
      {:ok, compiled} = Mydia.Settings.CustomFormats.Matcher.compile_patterns(patterns)

      %{
        slug: String.downcase(name),
        name: name,
        score: Keyword.get(opts, :score, 0),
        reject: Keyword.get(opts, :reject, false),
        patterns: compiled
      }
    end

    test "a rejecting format drops the release" do
      vfq = compiled_format("VFQ", ["\\bVFQ\\b"], reject: true)

      title_vfq = "Film.2024.VFQ.1080p.WEB-DL"
      title_vff = "Film.2024.VFF.1080p.WEB-DL"

      results = [
        build_result(%{title: title_vfq, seeders: 500}),
        build_result(%{title: title_vff, seeders: 5})
      ]

      kept = ReleaseRanker.filter_acceptable(results, custom_formats: [vfq])
      assert Enum.map(kept, & &1.title) == [title_vff]
    end

    test "format score outranks seeders within a resolution tier" do
      vff = compiled_format("VFF", ["\\bVFF\\b"], score: 100)

      title_vfq = "Film.2024.VFQ.1080p.WEB-DL"
      title_vff = "Film.2024.VFF.1080p.WEB-DL"

      results = [
        build_result(%{
          title: title_vfq,
          seeders: 500,
          quality: QualityParser.parse(title_vfq)
        }),
        build_result(%{
          title: title_vff,
          seeders: 5,
          quality: QualityParser.parse(title_vff)
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :movie,
          preferred_qualities: ["1080p"],
          custom_formats: [vff]
        )

      assert hd(ranked).result.title == title_vff
    end

    test "format score does not promote across resolution tiers" do
      vff = compiled_format("VFF", ["\\bVFF\\b"], score: 1000)

      title_vff_720 = "Film.2024.VFF.720p.WEB-DL"
      title_vfq_1080 = "Film.2024.VFQ.1080p.WEB-DL"

      results = [
        build_result(%{
          title: title_vff_720,
          seeders: 5,
          quality: QualityParser.parse(title_vff_720)
        }),
        build_result(%{
          title: title_vfq_1080,
          seeders: 5,
          quality: QualityParser.parse(title_vfq_1080)
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          media_type: :movie,
          preferred_qualities: ["1080p", "720p"],
          custom_formats: [vff]
        )

      assert hd(ranked).result.title == title_vfq_1080
    end

    test "with no formats the ordering is unchanged" do
      title_vfq = "Film.2024.VFQ.1080p.WEB-DL"
      title_vff = "Film.2024.VFF.1080p.WEB-DL"

      results = [
        build_result(%{
          title: title_vfq,
          seeders: 500,
          quality: QualityParser.parse(title_vfq)
        }),
        build_result(%{
          title: title_vff,
          seeders: 5,
          quality: QualityParser.parse(title_vff)
        })
      ]

      with_formats =
        ReleaseRanker.rank_all(results, media_type: :movie, preferred_qualities: ["1080p"])

      without_key =
        ReleaseRanker.rank_all(results,
          media_type: :movie,
          preferred_qualities: ["1080p"],
          custom_formats: []
        )

      assert Enum.map(with_formats, & &1.result.title) ==
               Enum.map(without_key, & &1.result.title)
    end

    test "breakdown carries the summed format score" do
      vff = compiled_format("VFF", ["\\bVFF\\b"], score: 100)
      title = "Film.2024.VFF.1080p.WEB-DL"
      result = build_result(%{title: title, seeders: 10})

      breakdown =
        ReleaseRanker.calculate_score_breakdown(result, media_type: :movie, custom_formats: [vff])

      assert breakdown.custom_format_score == 100
    end

    test "score_all_with_reasons reports the rejection reason" do
      vfq = compiled_format("VFQ", ["\\bVFQ\\b"], reject: true)
      title = "Film.2024.VFQ.1080p.WEB-DL"
      results = [build_result(%{title: title, seeders: 10})]

      [row] = ReleaseRanker.score_all_with_reasons(results, custom_formats: [vfq])
      assert row.status == :rejected
      assert row.rejection_reason == "custom_format: VFQ"
    end
  end
end
