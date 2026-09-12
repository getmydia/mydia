defmodule Mydia.Indexers.Adapter.NewznabTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Newznab
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.SearchResult

  @moduletag :indexers

  # Sample Newznab XML response for capabilities
  @sample_caps_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <caps>
    <server appname="NZBHydra2" version="5.3.0"/>
    <limits max="100" default="100"/>
    <registration available="no" open="no"/>
    <searching>
      <search available="yes" supportedParams="q"/>
      <tv-search available="yes" supportedParams="q,season,ep,tvdbid,rid"/>
      <movie-search available="yes" supportedParams="q,imdbid,tmdbid"/>
    </searching>
    <categories>
      <category id="2000" name="Movies">
        <subcat id="2010" name="Foreign"/>
        <subcat id="2020" name="Other"/>
      </category>
      <category id="5000" name="TV">
        <subcat id="5010" name="Anime"/>
        <subcat id="5020" name="Documentary"/>
      </category>
    </categories>
  </caps>
  """

  # Sample Newznab XML response for search
  @sample_search_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
    <channel>
      <title>NZBHydra2</title>
      <item>
        <title>Test.Movie.2024.1080p.WEB-DL.x264-GROUP</title>
        <guid>https://nzbhydra2.local/details/abc123</guid>
        <link>https://nzbhydra2.local/nzb/abc123</link>
        <comments>https://nzbhydra2.local/details/abc123</comments>
        <pubDate>Mon, 25 Nov 2024 10:30:00 +0000</pubDate>
        <enclosure url="https://nzbhydra2.local/nzb/abc123" length="2147483648" type="application/x-nzb"/>
        <newznab:attr name="size" value="2147483648"/>
        <newznab:attr name="grabs" value="150"/>
        <newznab:attr name="category" value="2000"/>
        <newznab:attr name="tmdbid" value="12345"/>
        <newznab:attr name="imdbid" value="tt1234567"/>
        <newznab:attr name="indexer" value="NZBGeek"/>
      </item>
      <item>
        <title>Another.Release.2024.720p.WEBRip.x265</title>
        <guid>https://nzbhydra2.local/details/def456</guid>
        <link>https://nzbhydra2.local/nzb/def456</link>
        <pubDate>Sun, 24 Nov 2024 15:00:00 +0000</pubDate>
        <enclosure url="https://nzbhydra2.local/nzb/def456" length="1073741824" type="application/x-nzb"/>
        <newznab:attr name="size" value="1073741824"/>
        <newznab:attr name="grabs" value="50"/>
        <newznab:attr name="category" value="5000"/>
      </item>
    </channel>
  </rss>
  """

  # Empty search response
  @empty_search_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
    <channel>
      <title>NZBHydra2</title>
    </channel>
  </rss>
  """

  defp build_config(bypass, opts \\ []) do
    %{
      type: :newznab,
      name: Keyword.get(opts, :name, "Test Newznab"),
      host: "localhost",
      port: bypass.port,
      api_key: Keyword.get(opts, :api_key, "test-api-key"),
      use_ssl: false,
      options: %{
        timeout: 30_000,
        base_path: Keyword.get(opts, :base_path),
        api_path: Keyword.get(opts, :api_path)
      }
    }
  end

  describe "test_connection/1" do
    test "successfully connects and parses capabilities" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        assert conn.query_string =~ "apikey=test-api-key"
        assert conn.query_string =~ "t=caps"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_caps_xml)
      end)

      config = build_config(bypass)
      assert {:ok, info} = Newznab.test_connection(config)
      assert info.name == "NZBHydra2"
      assert info.version == "5.3.0"
      assert info.app_name == "Newznab"
    end

    test "uses a custom API path for connection testing" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/proxy/newznab/api", fn conn ->
        assert conn.query_params["t"] == "caps"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_caps_xml)
      end)

      config = build_config(bypass, base_path: "/proxy", api_path: "/newznab/api")
      assert {:ok, _info} = Newznab.test_connection(config)
    end

    test "returns a typed error without issuing a request for an invalid API path" do
      bypass = Bypass.open()

      config = build_config(bypass, api_path: "https://indexer.test/api")

      assert {:error, %Error{type: :connection_failed, message: message}} =
               Newznab.test_connection(config)

      refute message =~ "HTTP"
    end

    test "returns error on authentication failure (401)" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(401, "Unauthorized")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :authentication_failed}} = Newznab.test_connection(config)
    end

    test "returns error on forbidden (403)" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(403, "Forbidden")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :authentication_failed}} = Newznab.test_connection(config)
    end

    test "returns error on server error" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(500, "Internal Server Error")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :connection_failed}} = Newznab.test_connection(config)
    end

    test "returns error on connection refused" do
      # Use a port that is not open
      config = %{
        type: :newznab,
        name: "Test Newznab",
        host: "localhost",
        port: 59999,
        api_key: "test-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Newznab.test_connection(config)
    end
  end

  describe "search/3" do
    test "successfully searches and parses results" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        assert conn.query_string =~ "apikey=test-api-key"
        assert conn.query_string =~ "t=search"
        assert conn.query_string =~ "q=test+movie"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_search_xml)
      end)

      config = build_config(bypass)
      assert {:ok, results} = Newznab.search(config, "test movie")

      assert length(results) == 2

      # Check first result
      result = Enum.at(results, 0)
      assert %SearchResult{} = result
      assert result.title == "Test.Movie.2024.1080p.WEB-DL.x264-GROUP"
      assert result.size == 2_147_483_648
      # NZB results have no seeders/leechers concept; grabs lives in nzb_grabs.
      assert result.seeders == nil
      assert result.leechers == nil
      assert result.nzb_grabs == 150
      assert result.download_url == "https://nzbhydra2.local/nzb/abc123"
      assert result.info_url == "https://nzbhydra2.local/details/abc123"
      assert result.indexer == "NZBGeek"
      assert result.category == 2000
      assert result.tmdb_id == 12345
      assert result.imdb_id == "tt1234567"
      assert result.download_protocol == :nzb

      # Check second result
      result2 = Enum.at(results, 1)
      assert result2.title == "Another.Release.2024.720p.WEBRip.x265"
      assert result2.size == 1_073_741_824
      assert result2.seeders == nil
      assert result2.nzb_grabs == 50
      assert result2.category == 5000
      assert result2.download_protocol == :nzb
    end

    test "uses a custom API path for search" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/custom/api", fn conn ->
        assert conn.query_params["t"] == "search"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_search_xml)
      end)

      config = build_config(bypass, api_path: "custom/api")
      assert {:ok, _results} = Newznab.search(config, "test")
    end

    test "returns empty list on no results" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @empty_search_xml)
      end)

      config = build_config(bypass)
      assert {:ok, []} = Newznab.search(config, "nonexistent")
    end

    test "includes category filter in request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        assert conn.query_string =~ "cat=2000%2C5000"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @empty_search_xml)
      end)

      config = build_config(bypass)
      assert {:ok, _} = Newznab.search(config, "test", categories: [2000, 5000])
    end

    test "includes limit in request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        assert conn.query_string =~ "limit=50"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @empty_search_xml)
      end)

      config = build_config(bypass)
      assert {:ok, _} = Newznab.search(config, "test", limit: 50)
    end

    test "returns error on authentication failure" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(401, "Unauthorized")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :authentication_failed}} = Newznab.search(config, "test")
    end

    test "returns error on rate limit" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(429, "Too Many Requests")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :rate_limited}} = Newznab.search(config, "test")
    end

    test "returns error on server error" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.resp(500, "Internal Server Error")
      end)

      config = build_config(bypass)
      assert {:error, %Error{type: :search_failed}} = Newznab.search(config, "test")
    end
  end

  describe "get_capabilities/1" do
    test "returns parsed capabilities" do
      bypass = Bypass.open()

      # get_capabilities calls test_connection first, then fetches capabilities
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_caps_xml)
      end)

      config = build_config(bypass)
      assert {:ok, capabilities} = Newznab.get_capabilities(config)

      assert is_map(capabilities.searching)
      assert capabilities.searching.search.available == true
      assert capabilities.searching.tv_search.available == true
      assert capabilities.searching.movie_search.available == true

      assert is_list(capabilities.categories)
      assert length(capabilities.categories) == 2

      movie_cat = Enum.find(capabilities.categories, &(&1.id == 2000))
      assert movie_cat.name == "Movies"

      tv_cat = Enum.find(capabilities.categories, &(&1.id == 5000))
      assert tv_cat.name == "TV"
    end
  end

  describe "adapter structure" do
    test "implements required callbacks" do
      # Ensure the module is loaded first — function_exported?/3 returns false
      # for a module that has not yet been loaded, which flakes under test
      # orderings where no prior test has referenced Newznab.
      assert Code.ensure_loaded?(Newznab)
      assert function_exported?(Newznab, :search, 3)
      assert function_exported?(Newznab, :test_connection, 1)
      assert function_exported?(Newznab, :get_capabilities, 1)
    end

    test "module exists and is loaded" do
      assert Code.ensure_loaded?(Newznab)
    end
  end

  describe "IMDB ID normalization" do
    test "normalizes IMDB ID with tt prefix" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
            <newznab:attr name="imdbid" value="1234567"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert result.imdb_id == "tt1234567"
    end

    test "preserves IMDB ID already with tt prefix" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
            <newznab:attr name="imdbid" value="tt9876543"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert result.imdb_id == "tt9876543"
    end
  end

  describe "quality parsing" do
    test "parses quality information from title" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test.Movie.2024.2160p.UHD.BluRay.x265.HDR.DTS-HD.MA-GROUP</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="50000000000" type="application/x-nzb"/>
            <newznab:attr name="grabs" value="200"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")

      assert result.quality != nil
      assert result.quality.resolution == "2160p"
    end
  end

  describe "Usenet-specific fields (#120)" do
    test "parses usenetdate into usenet_date" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test.NZB.Release</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
            <newznab:attr name="usenetdate" value="Mon, 25 Nov 2024 10:30:00 +0000"/>
            <newznab:attr name="grabs" value="42"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert %DateTime{} = result.usenet_date
      assert result.usenet_date.year == 2024
      assert result.usenet_date.month == 11
      assert result.usenet_date.day == 25
    end

    test "parses grabs into nzb_grabs and leaves seeders/leechers as nil" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test.NZB.Release</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
            <newznab:attr name="grabs" value="42"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert result.nzb_grabs == 42
      assert result.seeders == nil
      assert result.leechers == nil
    end

    test "parses completion attribute into nzb_completion as 0.0..1.0 float" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test.NZB.Release</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
            <newznab:attr name="completion" value="95"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert result.nzb_completion == 0.95
    end

    test "leaves usenet_date and nzb_completion as nil when fields are absent" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test.NZB.Release</title>
            <link>http://example.com/nzb</link>
            <enclosure url="http://example.com/nzb" length="1000" type="application/x-nzb"/>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Newznab.search(config, "test")
      assert result.usenet_date == nil
      assert result.nzb_completion == nil
      assert result.nzb_grabs == nil
    end
  end

  describe "use_ssl defaults (GitHub issue #28)" do
    test "test_connection works without use_ssl key in config" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_caps_xml)
      end)

      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :newznab,
        name: "Test Newznab",
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        options: %{}
      }

      assert {:ok, info} = Newznab.test_connection(config)
      assert info.name == "NZBHydra2"
    end

    test "search works without use_ssl key in config" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, @sample_search_xml)
      end)

      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :newznab,
        name: "Test Newznab",
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        options: %{}
      }

      assert {:ok, results} = Newznab.search(config, "test")
      assert length(results) == 2
    end
  end
end
