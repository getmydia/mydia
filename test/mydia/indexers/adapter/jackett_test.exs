defmodule Mydia.Indexers.Adapter.JackettTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Jackett
  alias Mydia.Indexers.Adapter.Error

  # Previously the whole module was tagged :external, which excluded every
  # test by default (including the Bypass-driven, fully offline ones). The
  # tests that genuinely need a live Jackett are individually tagged `:skip`,
  # and every remaining test is offline by construction (Bypass, or a port
  # Bypass has vacated), so no module-level gate is needed.

  describe "test_connection/1" do
    @tag :skip
    test "successfully connects to Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, info} = Jackett.test_connection(config)
      assert info.name == "Jackett"
      assert info.app_name == "Jackett"
    end

    @tag :skip
    test "fails with invalid API key" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end

    @tag :skip
    test "fails with invalid host" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "nonexistent.local",
        port: 9117,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end
  end

  describe "search/3" do
    @tag :skip
    test "successfully searches Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      assert {:ok, results} = Jackett.search(config, "ubuntu", limit: 5)
      assert is_list(results)
      assert results != []

      # Check first result has required fields
      result = hd(results)
      assert is_binary(result.title)
      assert is_integer(result.size)
      assert is_integer(result.seeders)
      assert is_integer(result.leechers)
      assert is_binary(result.download_url)
      assert is_binary(result.indexer)
    end

    @tag :skip
    test "searches with category filter" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000,
          categories: [2000]
        }
      }

      assert {:ok, results} = Jackett.search(config, "movie", limit: 5)
      assert is_list(results)
    end

    @tag :skip
    test "handles invalid API key" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: error_type}} = Jackett.search(config, "test")
      assert error_type in [:connection_failed, :search_failed]
    end

    @tag :skip
    test "handles search with empty query" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      # Empty queries should still work
      assert {:ok, _results} = Jackett.search(config, "")
    end
  end

  describe "get_capabilities/1" do
    @tag :skip
    test "fetches capabilities from Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, capabilities} = Jackett.get_capabilities(config)
      assert %{searching: searching, categories: categories} = capabilities
      assert is_map(searching)
      assert is_list(categories)

      # Check standard search capabilities
      assert searching.search.available == true
      assert searching.tv_search.available == true
      assert searching.movie_search.available == true
    end
  end

  describe "adapter structure" do
    test "implements required callbacks" do
      # Verify the adapter is properly structured
      #
      # function_exported?/3 answers false for a module that has not been
      # loaded yet, so without this the assertion races on whether some
      # earlier test in the run happened to reference Jackett first.
      Code.ensure_loaded!(Jackett)

      assert function_exported?(Jackett, :search, 3)
      assert function_exported?(Jackett, :test_connection, 1)
      assert function_exported?(Jackett, :get_capabilities, 1)
    end
  end

  describe "XML parsing" do
    test "handles empty search results" do
      # This would need mocking to test properly
      # For now, verify the module exists and has the expected structure
      assert Code.ensure_loaded?(Jackett)
    end
  end

  describe "use_ssl defaults (GitHub issue #28)" do
    # These two guard a real regression: a config with no :use_ssl key (what
    # the web UI produces) used to raise KeyError instead of failing
    # gracefully. That is why they must NOT be tagged :skip like the
    # network-dependent tests above -- skipping means the guard never runs.
    #
    # They used to point at port 9117, which made them environment-dependent
    # in exactly the way the :skip tags elsewhere in this file exist to avoid:
    # they passed on a machine with nothing listening there and failed on a
    # developer machine actually running Jackett. Opening a Bypass and
    # immediately shutting it down yields a port the OS just confirmed was
    # free and that now has nothing behind it, so the connection refusal is
    # guaranteed regardless of what is running locally.
    #
    # The connection target is incidental to what these assert: only that the
    # call returns an error tuple rather than raising. A KeyError would fail
    # the match below rather than satisfy it.
    setup do
      bypass = Bypass.open()
      port = bypass.port
      Bypass.down(bypass)

      {:ok, closed_port: port}
    end

    test "test_connection works without use_ssl key - fails gracefully", %{
      closed_port: closed_port
    } do
      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: closed_port,
        api_key: "test-api-key",
        options: %{}
      }

      # This should not crash with KeyError but return a connection error
      # (nothing is listening on closed_port)
      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end

    test "search works without use_ssl key - fails gracefully", %{closed_port: closed_port} do
      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: closed_port,
        api_key: "test-api-key",
        options: %{}
      }

      # This should not crash with KeyError but return a connection/search error
      # (nothing is listening on closed_port)
      assert {:error, %Error{type: error_type}} = Jackett.search(config, "test")
      assert error_type in [:connection_failed, :search_failed]
    end
  end

  describe "search/3 retry behavior" do
    setup do
      {:ok, bypass: Bypass.open()}
    end

    test "a failing search is attempted exactly once", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(500, "<error/>")
      end)

      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{timeout: 5_000}
      }

      assert {:error, _} = Jackett.search(config, "Ubuntu")

      assert Agent.get(counter, & &1) == 1,
             "expected exactly one attempt, Req retried a transient failure"
    end
  end

  describe "info_url guid fallback" do
    defp torznab_item(fields) do
      """
      <item>
        <title>Copper Lantern 2031 1080p WEB-DL x264-GRP</title>
        #{fields}
        <torznab:attr name="seeders" value="5"/>
        <torznab:attr name="peers" value="7"/>
      </item>
      """
    end

    defp search_one(item_xml) do
      bypass = Bypass.open()

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>#{item_xml}</channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api/v2.0/indexers/all/results/torznab/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, body)
      end)

      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{timeout: 5_000}
      }

      {:ok, [result]} = Jackett.search(config, "copper lantern")
      result
    end

    test "drops a guid that is the item's .torrent link" do
      result =
        search_one(
          torznab_item("""
          <guid>https://tracker.example/dl/42.torrent</guid>
          <link>https://tracker.example/dl/42.torrent</link>
          <enclosure url="https://tracker.example/dl/42.torrent" length="1000" type="application/x-bittorrent"/>
          """)
        )

      assert result.info_url == nil
    end

    test "drops a guid that matches a non-chosen download candidate" do
      # The magnet wins as download_url, but the guid is still the .torrent file.
      result =
        search_one(
          torznab_item("""
          <guid>https://tracker.example/dl/42.torrent</guid>
          <link>https://tracker.example/dl/42.torrent</link>
          <enclosure url="https://tracker.example/dl/42.torrent" length="1000" type="application/x-bittorrent"/>
          <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:aaa"/>
          """)
        )

      assert result.download_url == "magnet:?xt=urn:btih:aaa"
      assert result.info_url == nil
    end

    test "keeps a guid that differs from every download URL" do
      result =
        search_one(
          torznab_item("""
          <guid>https://tracker.example/details/42</guid>
          <link>https://tracker.example/dl/42.torrent</link>
          <enclosure url="https://tracker.example/dl/42.torrent" length="1000" type="application/x-bittorrent"/>
          """)
        )

      assert result.info_url == "https://tracker.example/details/42"
    end

    test "keeps a guid equal to the link when a direct download URL exists" do
      result =
        search_one(
          torznab_item("""
          <guid>https://tracker.example/details/42</guid>
          <link>https://tracker.example/details/42</link>
          <enclosure url="https://tracker.example/dl/42.torrent" length="1000" type="application/x-bittorrent"/>
          """)
        )

      assert result.info_url == "https://tracker.example/details/42"
    end

    test "keeps explicit comments even when equal to the download URL" do
      result =
        search_one(
          torznab_item("""
          <guid>https://tracker.example/t/42</guid>
          <comments>https://tracker.example/t/42</comments>
          <link>https://tracker.example/t/42</link>
          <enclosure url="https://tracker.example/t/42" length="1000" type="application/x-bittorrent"/>
          """)
        )

      assert result.info_url == "https://tracker.example/t/42"
    end
  end
end
