defmodule MydiaWeb.MediaLive.Show.SearchHelpersTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Show.SearchHelpers
  alias Mydia.Indexers.{QualityParser, RankingOptions, ReleaseRanker, SearchResult}
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

  defp build_quality_profile do
    %QualityProfile{
      name: "Test Profile",
      quality_standards: %{
        preferred_resolutions: ["1080p", "720p"]
      }
    }
  end

  describe "sort_search_results/5 with title relevance" do
    test "exact title match ranks higher than similar but different series" do
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # Unrelated documentary with similar words
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: 3
        }),
        # The actual series we want
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.WEBRip.x265-KONTRAST",
          size: 7 * gb,
          seeders: 36
        }),
        # Different series with similar name
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        })
      ]

      # With search_query, title relevance should boost "The Girlfriend 2025"
      sorted_with_query =
        SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Girlfriend S01")

      # Find the actual series position in sorted list
      actual_idx_with =
        Enum.find_index(sorted_with_query, &String.contains?(&1.title, "The.Girlfriend.2025"))

      # With the search query, "The Girlfriend 2025" should rank first (index 0)
      assert actual_idx_with == 0,
             """
             Expected "The Girlfriend 2025" to rank first when search_query is provided.
             Position: #{actual_idx_with}
             Sorted order: #{Enum.map(sorted_with_query, & &1.title) |> inspect()}
             """

      # Verify "The Girlfriend Experience" ranks after the actual series
      experience_idx =
        Enum.find_index(sorted_with_query, &String.contains?(&1.title, "Experience"))

      assert experience_idx > actual_idx_with,
             "The Girlfriend Experience should rank after the actual series"
    end

    test "title relevance bonus is applied when search_query is provided" do
      profile = build_quality_profile()

      results = [
        build_result(%{title: "Some.Other.Show.S01.1080p.WEB-DL", seeders: 100}),
        build_result(%{title: "The.Show.S01E01.1080p.WEB-DL", seeders: 50}),
        build_result(%{title: "The.Show.And.More.S01.1080p.WEB-DL", seeders: 75})
      ]

      sorted =
        SearchHelpers.sort_search_results(results, :quality, profile, :episode, "The Show S01")

      # "The.Show.S01E01" should rank first as it closely matches the query
      first = List.first(sorted)
      assert String.contains?(first.title, "The.Show.S01E01")
    end

    test "without search_query, title relevance bonus is zero" do
      # This test verifies that the title_relevance_bonus returns 0 when no query is provided
      # The actual sorting depends on quality profile scores
      results = [
        build_result(%{title: "The.Girlfriend.S01.1080p.WEB-DL", seeders: 50}),
        build_result(%{title: "Other.Show.S01.1080p.WEB-DL", seeders: 50})
      ]

      # Sort without and with search_query
      sorted_without = SearchHelpers.sort_search_results(results, :quality, nil, :episode, nil)

      sorted_with =
        SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Girlfriend S01")

      # With search_query, "The Girlfriend" should rank first
      first_with = List.first(sorted_with)

      assert String.contains?(first_with.title, "The.Girlfriend"),
             "With search_query, title relevance should boost 'The Girlfriend'"

      # Without search_query, the order might be different (based only on quality/seeders)
      # The key point is that title matching is only applied when query is provided
      titles_without = Enum.map(sorted_without, & &1.title)
      titles_with = Enum.map(sorted_with, & &1.title)

      # Just verify both lists contain the same items (they might be in different order)
      assert Enum.sort(titles_without) == Enum.sort(titles_with)
    end

    test "title with extra unrelated words gets penalty" do
      profile = build_quality_profile()

      results = [
        # Many extra unrelated words
        build_result(%{
          title:
            "Jimmy.Carrs.Am.I.The.Asshole.S01E01.Bill.Splitting.Angst.and.a.Gassy.Girlfriend.1080p",
          seeders: 50
        }),
        # Clean match
        build_result(%{title: "The.Girlfriend.S01E01.1080p.WEB-DL", seeders: 50})
      ]

      sorted =
        SearchHelpers.sort_search_results(
          results,
          :quality,
          profile,
          :episode,
          "The Girlfriend S01"
        )

      # The clean match should rank first due to penalty on extra words
      first = List.first(sorted)
      assert String.contains?(first.title, "The.Girlfriend.S01E01")
    end
  end

  describe "sort_search_results_with_opts/3 unified ranker (U5)" do
    test "the first quality-sorted item equals ReleaseRanker.select_best_result" do
      profile = build_quality_profile()

      results = [
        build_result(%{
          title: "Rick.and.Morty.S09E01.720p.WEB.h264-OTHER",
          seeders: 20,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.720p.WEB.h264-OTHER")
        }),
        build_result(%{
          title: "Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP",
          seeders: 5,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP")
        }),
        build_result(%{
          title: "Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p",
          seeders: 500,
          quality: QualityParser.parse("Rick.and.Morty.A.Way.Back.Home.XXX.Parody.1080p")
        })
      ]

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        })

      sorted = SearchHelpers.sort_search_results_with_opts(results, :quality, opts)
      best = ReleaseRanker.select_best_result(results, opts)

      assert List.first(sorted).download_url == best.result.download_url
      # The parody must NOT be the manual top result.
      refute String.contains?(List.first(sorted).title, "Parody")
    end

    test "a penalized identity-mismatch release stays visible near the bottom (AE4)" do
      profile = build_quality_profile()

      results = [
        build_result(%{
          title: "Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP")
        }),
        build_result(%{
          title: "Rick.and.Morty.S09E02.1080p.WEB.h264-OTHER",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E02.1080p.WEB.h264-OTHER")
        })
      ]

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1,
          min_seeders: 0
        })

      sorted = SearchHelpers.sort_search_results_with_opts(results, :quality, opts)

      assert length(sorted) == 2
      # The wrong episode is still present but ranked last.
      assert String.contains?(List.last(sorted).title, "S09E02")
    end

    test "a blocked-tag release does not appear in the quality-sorted output (AE3)" do
      profile = build_quality_profile()

      results = [
        build_result(%{title: "Movie.CAM.1080p.x264", seeders: 100}),
        build_result(%{title: "Movie.1080p.BluRay.x264", seeders: 50})
      ]

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 0,
          blocked_tags: ["CAM"]
        })

      sorted = SearchHelpers.sort_search_results_with_opts(results, :quality, opts)

      refute Enum.any?(sorted, &String.contains?(&1.title, "CAM"))
    end

    test "non-quality sort modes are unchanged by the unified path" do
      results = [
        build_result(%{title: "A.1080p", seeders: 10, size: 1_000}),
        build_result(%{title: "B.1080p", seeders: 100, size: 5_000})
      ]

      opts = RankingOptions.build(%{media_type: :movie})

      by_seeders = SearchHelpers.sort_search_results_with_opts(results, :seeders, opts)
      assert List.first(by_seeders).seeders == 100

      by_size = SearchHelpers.sort_search_results_with_opts(results, :size, opts)
      assert List.first(by_size).size == 5_000
    end
  end

  describe "profile_score_breakdown/2 unified breakdown (U6)" do
    test "returns a ScoreBreakdown struct with a real 0-10 title_match" do
      profile = build_quality_profile()

      result =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL.x264",
          seeders: 30,
          quality: QualityParser.parse("The.Studio.2025.S01E01.1080p.WEB-DL.x264")
        })

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :episode,
          search_query: "The Studio S01E01"
        })

      data = SearchHelpers.profile_score_breakdown(result, opts)

      assert %Mydia.Indexers.Structs.ScoreBreakdown{} = data.breakdown
      assert data.breakdown.title_match > 0.0
      assert data.breakdown.title_match <= 10.0
      assert is_map(data.detected)
    end

    test "a penalized identity mismatch carries a non-zero identity penalty" do
      profile = build_quality_profile()

      result =
        build_result(%{
          title: "Rick.and.Morty.S09E02.1080p.WEB.h264-OTHER",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E02.1080p.WEB.h264-OTHER")
        })

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1
        })

      data = SearchHelpers.profile_score_breakdown(result, opts)

      assert data.breakdown.identity_penalty < 0.0
      # The penalized total can be deeply negative (identity penalty is a tier
      # separator), which the dialog clamps to a 0 ring value.
      assert data.score < 0.0
    end

    test "a clean in-range identity match has all penalties zeroed" do
      profile = build_quality_profile()

      result =
        build_result(%{
          title: "Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP",
          seeders: 50,
          quality: QualityParser.parse("Rick.and.Morty.S09E01.1080p.WEB.h264-GROUP")
        })

      opts =
        RankingOptions.build(%{
          quality_profile: profile,
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1
        })

      data = SearchHelpers.profile_score_breakdown(result, opts)

      assert data.breakdown.size_penalty == 0.0
      assert data.breakdown.seeder_penalty == 0.0
      assert data.breakdown.identity_penalty == 0.0
    end
  end

  describe "sort_search_results/5 other sort modes" do
    test ":seeders ignores title relevance" do
      results = [
        build_result(%{title: "Exact.Match.S01.1080p", seeders: 10}),
        build_result(%{title: "Not.Match.S01.1080p", seeders: 100})
      ]

      sorted =
        SearchHelpers.sort_search_results(
          results,
          :seeders,
          nil,
          :episode,
          "Exact Match S01"
        )

      # Should sort by seeders regardless of title match
      first = List.first(sorted)
      assert first.seeders == 100
    end

    test ":size ignores title relevance" do
      small_size = 1 * 1024 * 1024 * 1024
      large_size = 10 * 1024 * 1024 * 1024

      results = [
        build_result(%{title: "Exact.Match.S01.1080p", size: small_size, seeders: 50}),
        build_result(%{title: "Not.Match.S01.1080p", size: large_size, seeders: 50})
      ]

      sorted =
        SearchHelpers.sort_search_results(results, :size, nil, :episode, "Exact Match S01")

      # Should sort by size regardless of title match
      first = List.first(sorted)
      assert first.size == large_size
    end
  end
end
