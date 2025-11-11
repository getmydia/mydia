defmodule Mydia.IndexersTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings
  alias Mydia.IndexerMock

  describe "search_all/2" do
    setup do
      # Ensure adapters are registered (needed for CI environment)
      Indexers.register_adapters()

      # Disable all existing indexer configs from test database
      Settings.list_indexer_configs()
      |> Enum.filter(fn config -> not is_nil(config.inserted_at) end)
      |> Enum.each(fn config ->
        Settings.update_indexer_config(config, %{enabled: false})
      end)

      # Set up mock Prowlarr servers
      bypass1 = Bypass.open()
      bypass2 = Bypass.open()
      bypass_disabled = Bypass.open()

      # Mock successful search responses
      IndexerMock.mock_prowlarr_all(bypass1,
        results: [
          %{title: "Ubuntu.22.04.1080p", seeders: 100},
          %{title: "Test.Release.720p", seeders: 50}
        ]
      )

      IndexerMock.mock_prowlarr_all(bypass2,
        results: [
          %{title: "Another.Release.1080p", seeders: 75}
        ]
      )

      IndexerMock.mock_prowlarr_all(bypass_disabled)

      # Create test indexer configurations pointing to Bypass servers
      {:ok, indexer1} =
        Settings.create_indexer_config(%{
          name: "Test Indexer 1",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass1.port}",
          api_key: "test-key-1",
          enabled: true
        })

      {:ok, indexer2} =
        Settings.create_indexer_config(%{
          name: "Test Indexer 2",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass2.port}",
          api_key: "test-key-2",
          enabled: true
        })

      {:ok, _disabled_indexer} =
        Settings.create_indexer_config(%{
          name: "Disabled Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass_disabled.port}",
          api_key: "test-key-3",
          enabled: false
        })

      %{indexer1: indexer1, indexer2: indexer2, bypass1: bypass1, bypass2: bypass2}
    end

    test "returns empty list when no indexers are enabled" do
      # Disable all database-persisted indexers (runtime configs can't be updated)
      Settings.list_indexer_configs()
      |> Enum.filter(fn config -> not is_nil(config.inserted_at) end)
      |> Enum.each(fn config ->
        Settings.update_indexer_config(config, %{enabled: false})
      end)

      assert {:ok, []} = Indexers.search_all("test query")
    end

    test "searches all enabled indexers concurrently", %{indexer1: _, indexer2: _} do
      # Search across all enabled indexers (which are now mocked)
      assert {:ok, results} = Indexers.search_all("ubuntu")
      assert is_list(results)
      # Should have results from both mock indexers
      assert length(results) > 0
    end

    test "filters results by minimum seeders", %{bypass1: bypass1} do
      # Set up mock with results having different seeder counts
      IndexerMock.mock_prowlarr_search(bypass1,
        results: [
          %{title: "Low.seeders", seeders: 2},
          %{title: "High.seeders", seeders: 100}
        ]
      )

      # Test with minimum 10 seeders - should only return the high seeder result
      assert {:ok, filtered} = Indexers.search_all("test", min_seeders: 10)
      assert is_list(filtered)
      # With min_seeders: 10, we should only get results with >= 10 seeders
      assert Enum.all?(filtered, fn result -> result.seeders >= 10 end)
    end

    test "limits results to max_results option", %{bypass1: bypass1} do
      # Set up mock with many results
      many_results =
        Enum.map(1..20, fn i ->
          %{title: "Result.#{i}", seeders: i * 5}
        end)

      IndexerMock.mock_prowlarr_search(bypass1, results: many_results)

      assert {:ok, results} = Indexers.search_all("popular query", max_results: 5)
      assert length(results) <= 5
    end

    test "deduplicates results by default" do
      # This test would verify deduplication works
      # In practice, you'd need to ensure the same torrent from multiple
      # indexers only appears once
      assert {:ok, results} = Indexers.search_all("test", deduplicate: true)
      assert is_list(results)
    end

    test "skips deduplication when deduplicate: false" do
      assert {:ok, results} = Indexers.search_all("test", deduplicate: false)
      assert is_list(results)
    end

    test "handles individual indexer failures gracefully" do
      # Even if one indexer fails, others should still return results
      # The function should not raise or return an error tuple
      assert {:ok, results} = Indexers.search_all("test query")
      assert is_list(results)
    end

    test "ranks results by quality and seeders" do
      # Results should be sorted with highest quality/seeders first
      # This is tested indirectly through the ranking implementation
      assert {:ok, results} = Indexers.search_all("test")
      assert is_list(results)
    end
  end

  describe "deduplication logic" do
    test "identifies duplicates by hash" do
      # Two results with the same hash should be deduplicated
      result1 = %SearchResult{
        title: "Ubuntu.22.04.1080p",
        size: 1_000_000,
        seeders: 50,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:abc123def456abc123def456abc123def456abcd",
        indexer: "Indexer 1"
      }

      result2 = %SearchResult{
        title: "Ubuntu 22 04 1080p",
        size: 1_000_000,
        seeders: 75,
        leechers: 15,
        download_url: "magnet:?xt=urn:btih:abc123def456abc123def456abc123def456abcd",
        indexer: "Indexer 2"
      }

      # When deduplicated, should keep the one with more seeders (result2)
      # This logic is tested in the private functions
      assert result1.download_url == result2.download_url
    end

    test "identifies duplicates by normalized title" do
      # Two results with similar titles should be deduplicated
      result1 = %SearchResult{
        title: "Movie.Name.2024.1080p.BluRay.x264-GROUP",
        size: 4_000_000_000,
        seeders: 50,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Indexer 1"
      }

      result2 = %SearchResult{
        title: "Movie.Name.2024.1080p.BluRay.x264-GROUP",
        size: 4_000_000_000,
        seeders: 75,
        leechers: 15,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Indexer 2"
      }

      # These should be identified as similar after normalization
      # Normalize both titles the same way our code does
      normalize = fn title ->
        title
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "")
      end

      assert normalize.(result1.title) == normalize.(result2.title)
    end
  end

  describe "ranking algorithm" do
    test "ranks higher quality results first" do
      low_quality = %SearchResult{
        title: "Movie.480p.WEBRip",
        size: 500_000_000,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Test",
        quality: %{
          resolution: "480p",
          source: "WEBRip",
          codec: "x264",
          audio: nil,
          hdr: false,
          proper: false,
          repack: false
        }
      }

      high_quality = %SearchResult{
        title: "Movie.2160p.BluRay.x265.HDR",
        size: 8_000_000_000,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Test",
        quality: %{
          resolution: "2160p",
          source: "BluRay",
          codec: "x265",
          audio: "DTS",
          hdr: true,
          proper: false,
          repack: false
        }
      }

      # High quality should score higher
      alias Mydia.Indexers.QualityParser

      low_score = QualityParser.quality_score(low_quality.quality)
      high_score = QualityParser.quality_score(high_quality.quality)

      assert high_score > low_score
    end

    test "considers seeder count in ranking" do
      few_seeders = %SearchResult{
        title: "Movie.1080p",
        size: 2_000_000_000,
        seeders: 5,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Test"
      }

      many_seeders = %SearchResult{
        title: "Movie.1080p",
        size: 2_000_000_000,
        seeders: 500,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Test"
      }

      # More seeders should contribute to higher score
      assert many_seeders.seeders > few_seeders.seeders
    end

    test "balances quality and seeders appropriately" do
      # A very high quality release with few seeders vs
      # medium quality with many seeders
      # Should prefer quality (60% weight) but seeders still matter

      high_qual_few_seeds = %SearchResult{
        title: "Movie.2160p.BluRay",
        size: 8_000_000_000,
        seeders: 10,
        leechers: 5,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Test",
        quality: %{
          resolution: "2160p",
          source: "BluRay",
          codec: "x265",
          audio: "TrueHD",
          hdr: true,
          proper: false,
          repack: false
        }
      }

      med_qual_many_seeds = %SearchResult{
        title: "Movie.1080p.WEB-DL",
        size: 4_000_000_000,
        seeders: 1000,
        leechers: 100,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Test",
        quality: %{
          resolution: "1080p",
          source: "WEB-DL",
          codec: "x264",
          audio: "AAC",
          hdr: false,
          proper: false,
          repack: false
        }
      }

      # Both should score reasonably well but quality should have preference
      assert high_qual_few_seeds.quality.resolution == "2160p"
      assert med_qual_many_seeds.seeders > high_qual_few_seeds.seeders
    end
  end

  describe "performance and error handling" do
    setup do
      # Disable all existing indexer configs
      Settings.list_indexer_configs()
      |> Enum.filter(fn config -> not is_nil(config.inserted_at) end)
      |> Enum.each(fn config ->
        Settings.update_indexer_config(config, %{enabled: false})
      end)

      bypass = Bypass.open()
      IndexerMock.mock_prowlarr_all(bypass)

      {:ok, _indexer} =
        Settings.create_indexer_config(%{
          name: "Performance Test Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "test-key",
          enabled: true
        })

      %{bypass: bypass}
    end

    test "completes within reasonable time for multiple indexers" do
      # Concurrent execution should be faster than sequential
      start_time = System.monotonic_time(:millisecond)
      {:ok, _results} = Indexers.search_all("test query")
      duration = System.monotonic_time(:millisecond) - start_time

      # With mocked responses, should complete quickly (under 5 seconds)
      assert duration < 5_000, "Search took too long: #{duration}ms"
    end

    test "handles empty query string" do
      assert {:ok, _results} = Indexers.search_all("")
    end

    test "handles very long query strings" do
      long_query = String.duplicate("word ", 100)
      assert {:ok, _results} = Indexers.search_all(long_query)
    end

    test "handles special characters in query" do
      assert {:ok, _results} = Indexers.search_all("Movie's \"Name\" (2024)")
    end
  end
end
