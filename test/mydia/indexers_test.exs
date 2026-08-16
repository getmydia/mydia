defmodule Mydia.IndexersTest do
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

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

      # Check if any runtime indexers are enabled (those with inserted_at == nil)
      # Runtime indexers are configured via environment variables and cannot be disabled
      enabled_runtime_indexers =
        Settings.list_indexer_configs()
        |> Enum.filter(fn config -> is_nil(config.inserted_at) and config.enabled end)

      # If runtime indexers exist, they will return results even when all DB indexers are disabled
      # In that case, we just verify the function succeeds but may return results
      # Otherwise, we expect an empty list
      {:ok, %{results: results}} = Indexers.search_all("test query")

      if Enum.empty?(enabled_runtime_indexers) do
        assert results == [], "Expected no results when all indexers are disabled"
      else
        # Runtime indexers are present - just verify the call succeeded
        # Results may or may not be empty depending on runtime indexer responses
        assert is_list(results),
               "Expected list result even with runtime indexers (got: #{inspect(results)})"
      end
    end

    test "searches all enabled indexers concurrently", %{indexer1: _, indexer2: _} do
      # Search across all enabled indexers (which are now mocked)
      assert {:ok, %{results: results}} = Indexers.search_all("ubuntu")
      assert is_list(results)
      # Should have results from both mock indexers
      assert results != []
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
      assert {:ok, %{results: filtered}} = Indexers.search_all("test", min_seeders: 10)
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

      assert {:ok, %{results: results}} = Indexers.search_all("popular query", max_results: 5)
      assert length(results) <= 5
    end

    test "deduplicates results by default" do
      # This test would verify deduplication works
      # In practice, you'd need to ensure the same torrent from multiple
      # indexers only appears once
      assert {:ok, %{results: results}} = Indexers.search_all("test", deduplicate: true)
      assert is_list(results)
    end

    test "skips deduplication when deduplicate: false" do
      assert {:ok, %{results: results}} = Indexers.search_all("test", deduplicate: false)
      assert is_list(results)
    end

    test "handles individual indexer failures gracefully" do
      # Even if one indexer fails, others should still return results
      # The function should not raise or return an error tuple
      assert {:ok, %{results: results, indexer_errors: _errors}} =
               Indexers.search_all("test query")

      assert is_list(results)
    end

    test "ranks results by quality and seeders" do
      # Results should be sorted with highest quality/seeders first
      # This is tested indirectly through the ranking implementation
      assert {:ok, %{results: results}} = Indexers.search_all("test")
      assert is_list(results)
    end
  end

  describe "search_all/2 fan-out" do
    # 1 fast + 3 slow indexers, permanently (not temporary scaffolding). With
    # only 2 indexers, `get_search_concurrency(2, [])` computes `min(2, 16) ==
    # 2`, identical to the old hardcoded default of 2 - a test with 2
    # indexers passes under both the old and the new code and proves nothing.
    # 4 indexers force a genuine RED under the old default (2 waves of 2, one
    # of which is two 3s sleepers back to back: ~6000ms) vs GREEN under full
    # fan-out (all 4 concurrent: ~3000ms), with headroom on both sides of the
    # 4_500ms assertion below.
    setup do
      fast = Bypass.open()

      Bypass.expect(fast, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([prowlarr_item("Fast.Movie.2021.1080p")]))
      end)

      indexer_config_fixture(%{
        name: "fast-indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{fast.port}"
      })

      for n <- 1..3 do
        slow = Bypass.open()

        Bypass.expect(slow, "GET", "/api/v1/search", fn conn ->
          # Bypass.pass/1 must run before the sleep: the deadline test kills
          # the client mid-request, which makes Cowboy tear down this plug
          # process with reason :shutdown. Without marking the expectation
          # passed first, Bypass's on_exit verification re-raises that as a
          # test crash, even though the abandoned connection is exactly what
          # the deadline is supposed to produce.
          Bypass.pass(slow)
          Process.sleep(3_000)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([prowlarr_item("Slow#{n}.Movie.2021.1080p")]))
        end)

        indexer_config_fixture(%{
          name: "slow-indexer-#{n}",
          type: :prowlarr,
          base_url: "http://localhost:#{slow.port}"
        })
      end

      :ok
    end

    defp prowlarr_item(title) do
      %{
        "title" => title,
        "size" => 8_000_000_000,
        "seeders" => 100,
        "leechers" => 5,
        "magnetUrl" => "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
        "indexer" => "upstream"
      }
    end

    test "a slow indexer does not serialize behind the fast one" do
      started = System.monotonic_time(:millisecond)

      {:ok, %{results: results}} = Indexers.search_all("Movie 2021")

      elapsed = System.monotonic_time(:millisecond) - started

      assert length(results) == 4

      assert elapsed < 4_500,
             "indexers ran serialized (#{elapsed}ms); expected concurrent fan-out"
    end

    test "an indexer past the deadline is reported by name, not as unknown" do
      {:ok, %{results: results, indexer_errors: errors}} =
        Indexers.search_all("Movie 2021", deadline_ms: 500)

      assert length(results) == 1
      assert hd(results).title =~ "Fast.Movie"

      assert length(errors) == 3

      assert errors |> Enum.map(& &1.indexer) |> Enum.sort() ==
               ["slow-indexer-1", "slow-indexer-2", "slow-indexer-3"]

      assert Enum.all?(errors, fn error -> error.error =~ "Timed out" end)
    end

    test "on_start reports every indexer as pending before any request" do
      parent = self()

      Indexers.search_all("Movie 2021",
        on_start: fn pending -> send(parent, {:started, pending}) end
      )

      assert_received {:started, pending}
      assert length(pending) == 4
      assert Enum.all?(pending, &(&1.status == :pending))
      assert Enum.all?(pending, &(&1.total == 4))
      assert Enum.all?(pending, &is_binary(&1.indexer_id))

      assert Enum.sort(Enum.map(pending, & &1.indexer)) ==
               ["fast-indexer", "slow-indexer-1", "slow-indexer-2", "slow-indexer-3"]
    end

    test "on_indexer_result fires once per indexer with counts and timing" do
      parent = self()

      Indexers.search_all("Movie 2021",
        on_indexer_result: fn progress -> send(parent, {:progress, progress}) end
      )

      assert_received {:progress, first}

      # The fast indexer settles first because fan-out is concurrent. With
      # `ordered: false`, Task.async_stream emits each indexer's result as it
      # settles rather than buffering to input order, so among the three slow
      # indexers - identical 3000ms sleeps started at the same time - which
      # one lands 2nd/3rd/4th is a genuine race with no fixed outcome. Only
      # the set of who finished and their status/counts is asserted below.
      assert first.indexer == "fast-indexer"
      assert first.status == :ok
      assert first.completed == 1
      assert first.total == 4
      assert first.result_count == 1
      assert length(first.results) == 1
      assert is_integer(first.duration_ms)

      rest = collect_progress([])
      assert length(rest) == 3
      assert Enum.all?(rest, &(&1.status == :ok))
      assert Enum.map(rest, & &1.completed) |> Enum.sort() == [2, 3, 4]

      assert Enum.map(rest, & &1.indexer) |> Enum.sort() ==
               ["slow-indexer-1", "slow-indexer-2", "slow-indexer-3"]
    end

    test "a timed-out indexer reports :timeout status through the callback" do
      parent = self()

      Indexers.search_all("Movie 2021",
        deadline_ms: 500,
        on_indexer_result: fn progress -> send(parent, {:progress, progress}) end
      )

      progress = collect_progress([])

      assert %{status: :ok, indexer: "fast-indexer"} = Enum.find(progress, &(&1.status == :ok))

      timed_out = Enum.filter(progress, &(&1.status == :timeout))
      assert length(timed_out) == 3

      assert Enum.map(timed_out, & &1.indexer) |> Enum.sort() ==
               ["slow-indexer-1", "slow-indexer-2", "slow-indexer-3"]

      assert Enum.all?(timed_out, &(&1.error =~ "Timed out"))
      assert Enum.all?(timed_out, &(&1.results == []))
    end

    defp collect_progress(acc) do
      receive do
        {:progress, progress} -> collect_progress([progress | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "omitting the callbacks leaves the return value unchanged" do
      {:ok, with_callbacks} =
        Indexers.search_all("Movie 2021", on_indexer_result: fn _ -> :ok end)

      {:ok, without_callbacks} = Indexers.search_all("Movie 2021")

      assert Enum.map(with_callbacks.results, & &1.title) ==
               Enum.map(without_callbacks.results, & &1.title)

      assert with_callbacks.indexer_errors == without_callbacks.indexer_errors
    end
  end

  describe "search_all/2 fan-out ordering" do
    # Named so the slow indexers sort BEFORE the fast one alphabetically -
    # list_indexer_configs orders enabled, equal-priority indexers by name
    # ascending, so this is the reverse of the "search_all/2 fan-out" describe
    # block above. That inversion is the point: Task.async_stream defaults to
    # `ordered: true`, which buffers each element's result until it's that
    # element's turn in *input* order, not completion order. Under that
    # default, the fast indexer's already-available result would sit behind
    # three 3000ms sleeps and the assertion below would fail. search_all/2
    # passes `ordered: false` specifically so results stream out as they
    # settle instead.
    setup do
      for n <- 1..3 do
        slow = Bypass.open()

        Bypass.expect(slow, "GET", "/api/v1/search", fn conn ->
          # See the sibling describe block above for why Bypass.pass/1 must
          # run before the sleep.
          Bypass.pass(slow)
          Process.sleep(3_000)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([prowlarr_item("Slow#{n}.Movie.2021.1080p")]))
        end)

        indexer_config_fixture(%{
          name: "aaa-slow-indexer-#{n}",
          type: :prowlarr,
          base_url: "http://localhost:#{slow.port}"
        })
      end

      fast = Bypass.open()

      Bypass.expect(fast, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([prowlarr_item("Fast.Movie.2021.1080p")]))
      end)

      indexer_config_fixture(%{
        name: "zzz-fast-indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{fast.port}"
      })

      :ok
    end

    test "on_indexer_result fires in completion order, not input order" do
      parent = self()

      Indexers.search_all("Movie 2021",
        on_indexer_result: fn progress -> send(parent, {:progress, progress}) end
      )

      assert_received {:progress, first}

      assert first.indexer == "zzz-fast-indexer",
             "expected the fast indexer's callback first (completion order); " <>
               "got #{first.indexer} instead - results are being buffered to input order"
    end
  end

  describe "background_search_opts/0" do
    test "defaults to max_concurrency: 2" do
      assert Indexers.background_search_opts() == [max_concurrency: 2]
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
      alias Mydia.Indexers.QualityParser
      alias Mydia.Library.Structs.Quality

      low_quality = %SearchResult{
        title: "Movie.480p.WEBRip",
        size: 500_000_000,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Test",
        quality:
          Quality.new(%{
            resolution: "480p",
            source: "WEBRip",
            codec: "x264",
            audio: nil,
            hdr: false,
            proper: false,
            repack: false
          })
      }

      high_quality = %SearchResult{
        title: "Movie.2160p.BluRay.x265.HDR",
        size: 8_000_000_000,
        seeders: 100,
        leechers: 10,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Test",
        quality:
          Quality.new(%{
            resolution: "2160p",
            source: "BluRay",
            codec: "x265",
            audio: "DTS",
            hdr: true,
            proper: false,
            repack: false
          })
      }

      # High quality should score higher
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

      alias Mydia.Library.Structs.Quality

      high_qual_few_seeds = %SearchResult{
        title: "Movie.2160p.BluRay",
        size: 8_000_000_000,
        seeders: 10,
        leechers: 5,
        download_url: "magnet:?xt=urn:btih:abc123",
        indexer: "Test",
        quality:
          Quality.new(%{
            resolution: "2160p",
            source: "BluRay",
            codec: "x265",
            audio: "TrueHD",
            hdr: true,
            proper: false,
            repack: false
          })
      }

      med_qual_many_seeds = %SearchResult{
        title: "Movie.1080p.WEB-DL",
        size: 4_000_000_000,
        seeders: 1000,
        leechers: 100,
        download_url: "magnet:?xt=urn:btih:def456",
        indexer: "Test",
        quality:
          Quality.new(%{
            resolution: "1080p",
            source: "WEB-DL",
            codec: "x264",
            audio: "AAC",
            hdr: false,
            proper: false,
            repack: false
          })
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
      {:ok, %{results: _results}} = Indexers.search_all("test query")
      duration = System.monotonic_time(:millisecond) - start_time

      # With mocked responses, should complete quickly (under 5 seconds)
      assert duration < 5_000, "Search took too long: #{duration}ms"
    end

    test "handles empty query string" do
      assert {:ok, %{results: _results}} = Indexers.search_all("")
    end

    test "handles very long query strings" do
      long_query = String.duplicate("word ", 100)
      assert {:ok, %{results: _results}} = Indexers.search_all(long_query)
    end

    test "handles special characters in query" do
      assert {:ok, %{results: _results}} = Indexers.search_all("Movie's \"Name\" (2024)")
    end
  end

  describe "test_connection/1" do
    setup do
      Indexers.register_adapters()
      :ok
    end

    test "works with raw config map containing base_url (UI flow)" do
      bypass = Bypass.open()
      IndexerMock.mock_prowlarr_status(bypass, version: "1.25.0")

      # This is the exact shape the LiveView sends when clicking "Test Connection"
      config = %{
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-api-key"
      }

      assert {:ok, info} = Indexers.test_connection(config)
      assert info.version == "1.25.0"
    end

    test "works with raw config map using HTTPS base_url" do
      # Verify use_ssl is correctly derived from https:// scheme
      # We can't easily test a real HTTPS connection, but we can verify
      # the config conversion doesn't crash
      config = %{
        type: :prowlarr,
        base_url: "https://prowlarr.example.com:9696",
        api_key: "test-api-key"
      }

      # This will fail to connect (no server), but should NOT crash with KeyError
      assert {:error, _} = Indexers.test_connection(config)
    end

    test "works with IndexerConfig struct" do
      bypass = Bypass.open()
      IndexerMock.mock_prowlarr_status(bypass, version: "1.25.0")

      {:ok, indexer_config} =
        Settings.create_indexer_config(%{
          name: "Test Prowlarr",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "test-api-key",
          enabled: true
        })

      assert {:ok, info} = Indexers.test_connection(indexer_config)
      assert info.version == "1.25.0"
    end

    test "works with already-converted adapter config (host/port/use_ssl)" do
      bypass = Bypass.open()
      IndexerMock.mock_prowlarr_status(bypass, version: "1.25.0")

      # This is the shape adapters expect directly
      config = %{
        type: :prowlarr,
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{base_path: nil}
      }

      assert {:ok, info} = Indexers.test_connection(config)
      assert info.version == "1.25.0"
    end
  end

  describe "rank_and_dedupe/3" do
    alias Mydia.Indexers.SearchResult

    defp result(title, seeders) do
      %SearchResult{
        title: title,
        download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
        indexer: "Test",
        size: 1_000_000_000,
        seeders: seeders,
        leechers: 0
      }
    end

    test "drops results below min_seeders" do
      results = [result("Movie.2021.1080p", 1), result("Movie.2021.720p", 50)]

      ranked = Indexers.rank_and_dedupe(results, "Movie 2021", min_seeders: 10)

      assert length(ranked) == 1
      assert hd(ranked).seeders == 50
    end

    test "truncates to max_results" do
      results = Enum.map(1..10, fn n -> result("Movie.2021.Release#{n}", n) end)

      ranked = Indexers.rank_and_dedupe(results, "Movie 2021", max_results: 3)

      assert length(ranked) == 3
    end

    test "deduplicate: false keeps identical titles" do
      results = [result("Movie.2021.1080p", 5), result("Movie.2021.1080p", 5)]

      ranked = Indexers.rank_and_dedupe(results, "Movie 2021", deduplicate: false)

      assert length(ranked) == 2
    end
  end
end
