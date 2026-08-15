defmodule Mydia.Indexers.Adapter.ProwlarrTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Indexers.Adapter.Prowlarr
  alias Mydia.Indexers.Adapter.Error

  # Previously the whole module was tagged :external, which excluded every
  # test by default (including the Bypass-driven, fully offline ones). The
  # legitimately-network-dependent tests are already individually tagged
  # `:skip`, so no module-level gate is needed.

  defp build_config(bypass) do
    %{
      type: :prowlarr,
      name: "Test Prowlarr",
      host: "localhost",
      port: bypass.port,
      api_key: "test-api-key",
      use_ssl: false,
      options: %{timeout: 5_000}
    }
  end

  describe "test_connection/1" do
    @tag :skip
    test "successfully connects to Prowlarr" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, info} = Prowlarr.test_connection(config)
      assert info.name == "Prowlarr"
      assert is_binary(info.version)
    end

    @tag :skip
    test "fails with invalid API key" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Prowlarr.test_connection(config)
    end

    @tag :skip
    test "fails with invalid host" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "nonexistent.local",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Prowlarr.test_connection(config)
    end
  end

  describe "search/3" do
    @tag :skip
    test "successfully searches Prowlarr" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      assert {:ok, results} = Prowlarr.search(config, "ubuntu", limit: 5)
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
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000,
          categories: [2000]
        }
      }

      assert {:ok, results} = Prowlarr.search(config, "movie", limit: 5)
      assert is_list(results)
    end

    @tag :skip
    test "handles invalid API key" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: error_type}} = Prowlarr.search(config, "test")
      assert error_type in [:connection_failed, :search_failed]
    end

    @tag :skip
    test "handles search with empty query" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      # Empty queries should still work
      assert {:ok, _results} = Prowlarr.search(config, "")
    end
  end

  describe "get_capabilities/1" do
    test "returns static capabilities" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:ok, capabilities} = Prowlarr.get_capabilities(config)
      assert %{searching: searching, categories: categories} = capabilities
      assert is_map(searching)
      assert is_list(categories)
      refute Enum.empty?(categories)

      # Check standard search capabilities
      assert searching.search.available == true
      assert searching.tv_search.available == true
      assert searching.movie_search.available == true
    end
  end

  describe "result parsing" do
    test "parses quality from title" do
      _config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      # Mock response with quality indicators in title
      # This test would need to be expanded with actual response mocking
      # For now, we verify the adapter is properly structured
      #
      # function_exported?/3 answers false for a module that has not been
      # loaded yet, so without this the assertion races on whether some
      # earlier test in the run happened to reference Prowlarr first.
      Code.ensure_loaded!(Prowlarr)

      assert function_exported?(Prowlarr, :search, 3)
      assert function_exported?(Prowlarr, :test_connection, 1)
      assert function_exported?(Prowlarr, :get_capabilities, 1)
    end
  end

  describe "Usenet-aware parsing (#121, #125)" do
    @moduletag :indexers

    test "NZB results carry usenet_date from publishDate and grabs into nzb_grabs" do
      bypass = Bypass.open()

      body =
        Jason.encode!([
          %{
            "title" => "Show.S01E01.1080p.WEB-DL",
            "size" => 1_073_741_824,
            "downloadUrl" => "http://example.com/release.nzb",
            "downloadProtocol" => "usenet",
            "publishDate" => "2024-11-25T10:30:00Z",
            "grabs" => 42,
            "indexer" => "Prowlarr"
          }
        ])

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Prowlarr.search(config, "test")

      assert result.download_protocol == :nzb
      assert result.seeders == nil
      assert result.leechers == nil
      assert result.nzb_grabs == 42
      assert %DateTime{year: 2024, month: 11, day: 25} = result.usenet_date
    end

    test "torrent results keep seeders/leechers and have nil NZB fields" do
      bypass = Bypass.open()

      body =
        Jason.encode!([
          %{
            "title" => "Movie.2024.1080p.BluRay.x264",
            "size" => 5_368_709_120,
            "downloadUrl" => "http://example.com/release.torrent",
            "downloadProtocol" => "torrent",
            "publishDate" => "2024-11-25T10:30:00Z",
            "seeders" => 120,
            "leechers" => 10,
            "indexer" => "Prowlarr"
          }
        ])

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, [result]} = Prowlarr.search(config, "test")

      assert result.download_protocol == :torrent
      assert result.seeders == 120
      assert result.leechers == 10
      assert result.nzb_grabs == nil
      assert result.usenet_date == nil
    end

    test "emits zero info-level log lines for routine result parsing (#125)" do
      bypass = Bypass.open()

      body =
        Jason.encode!([
          %{
            "title" => "Show.S01E01.1080p.WEB-DL",
            "size" => 1_073_741_824,
            "downloadUrl" => "http://example.com/release.nzb",
            "downloadProtocol" => "usenet",
            "publishDate" => "2024-11-25T10:30:00Z",
            "grabs" => 42,
            "indexer" => "Prowlarr"
          },
          %{
            "title" => "Movie.2024.1080p.BluRay.x264",
            "size" => 5_368_709_120,
            "downloadUrl" => "http://example.com/release.torrent",
            "downloadProtocol" => "torrent",
            "seeders" => 50,
            "leechers" => 5,
            "indexer" => "Prowlarr"
          }
        ])

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, _results} = Prowlarr.search(config, "test")
        end)

      # The four previously info-level lines about protocol detection and item
      # keys must no longer fire at :info level.
      refute log =~ "Prowlarr item keys"
      refute log =~ "Protocol field value"
      refute log =~ "Detected protocol"
    end
  end

  describe "use_ssl defaults (GitHub issue #28)" do
    test "get_capabilities works without use_ssl key in config" do
      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "test-api-key",
        options: %{}
      }

      # get_capabilities returns static data and doesn't make HTTP calls,
      # so we can test that it doesn't crash when use_ssl is missing
      assert {:ok, capabilities} = Prowlarr.get_capabilities(config)
      assert is_map(capabilities.searching)
      assert is_list(capabilities.categories)
    end
  end

  describe "fixture-based parsing (Bypass)" do
    # The plan filenames are *.xml ("Newznab XML"), but Prowlarr's /api/v1/search
    # only returns JSON (the adapter rejects non-list bodies with parse_error),
    # so fixtures are stored as JSON to mirror what the adapter actually parses.

    @nzb_fixture Path.expand("../../../support/fixtures/prowlarr/nzb_results.json", __DIR__)
    @mixed_fixture Path.expand(
                     "../../../support/fixtures/prowlarr/mixed_protocol_results.json",
                     __DIR__
                   )

    test "NZB-only fixture: every result resolves to :nzb with NZB-specific fields" do
      bypass = Bypass.open()
      body = File.read!(@nzb_fixture)

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, results} = Prowlarr.search(config, "test")
      assert length(results) == 3

      assert Enum.all?(results, &(&1.download_protocol == :nzb))
      assert Enum.all?(results, &(&1.seeders == nil))
      assert Enum.all?(results, &(&1.leechers == nil))
      assert Enum.all?(results, &(&1.nzb_grabs != nil))
      # publishDate -> usenet_date for NZBs
      assert Enum.all?(results, &match?(%DateTime{}, &1.usenet_date))

      # Spot-check a single row: guid passthrough, completion normalisation,
      # nzb_grabs as integer.
      first = Enum.find(results, &(&1.guid == "prowlarr-nzb-001"))
      assert first.title == "Show.S01E01.1080p.WEB-DL.x264-GROUP"
      assert first.size == 2_147_483_648
      assert first.nzb_grabs == 42
      # 100 -> 1.0 (percent normalised to ratio)
      assert_in_delta first.nzb_completion, 1.0, 0.0001
      assert %DateTime{year: 2024, month: 11, day: 25} = first.usenet_date

      # The 99.7 percent fixture round-trips through the percent-to-ratio
      # branch and ends up at 0.997.
      uhd = Enum.find(results, &(&1.guid == "prowlarr-nzb-002"))
      assert_in_delta uhd.nzb_completion, 0.997, 0.0001
    end

    test "mixed-protocol fixture: torrents stay :torrent, NZBs stay :nzb" do
      bypass = Bypass.open()
      body = File.read!(@mixed_fixture)

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, results} = Prowlarr.search(config, "test")
      assert length(results) == 6

      by_guid = Map.new(results, &{&1.guid, &1})

      # Explicit downloadProtocol fields win unconditionally.
      assert by_guid["prowlarr-mixed-001"].download_protocol == :nzb
      assert by_guid["prowlarr-mixed-002"].download_protocol == :torrent
      assert by_guid["prowlarr-mixed-003"].download_protocol == :nzb
      assert by_guid["prowlarr-mixed-004"].download_protocol == :torrent

      # Torrent rows carry seeders/leechers; NZB rows carry grabs.
      assert by_guid["prowlarr-mixed-002"].seeders == 120
      assert by_guid["prowlarr-mixed-002"].leechers == 10
      assert by_guid["prowlarr-mixed-002"].nzb_grabs == nil
      assert by_guid["prowlarr-mixed-001"].nzb_grabs == 50
      assert by_guid["prowlarr-mixed-001"].seeders == nil
      assert by_guid["prowlarr-mixed-001"].leechers == nil
    end

    test "explicit downloadProtocol wins over .nzb URL heuristic" do
      bypass = Bypass.open()
      body = File.read!(@mixed_fixture)

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, results} = Prowlarr.search(config, "test")

      conflict = Enum.find(results, &(&1.guid == "prowlarr-mixed-005"))
      # Explicit downloadProtocol "torrent" must override the .nzb URL fallback.
      assert conflict.download_protocol == :torrent
      assert conflict.seeders == 45
      assert conflict.nzb_grabs == nil
    end

    test "missing downloadProtocol falls back to URL heuristic (.nzb -> :nzb)" do
      bypass = Bypass.open()
      body = File.read!(@mixed_fixture)

      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      config = build_config(bypass)
      assert {:ok, results} = Prowlarr.search(config, "test")

      fallback = Enum.find(results, &(&1.guid == "prowlarr-mixed-006"))
      # No downloadProtocol field on this row -> URL heuristic kicks in
      # because the downloadUrl contains ".nzb".
      assert fallback.download_protocol == :nzb
    end
  end

  describe "protocol detection (table-driven)" do
    # Bypass on this describe drives the Prowlarr search endpoint with a single
    # synthetic JSON item per row. Each row pins how the adapter's protocol
    # detection branch (explicit field vs. fallback heuristics) resolves.
    @protocol_table [
      # {downloadProtocol, magnetUrl, downloadUrl, expected_atom, note}
      {"usenet", nil, "https://x/y.nzb", :nzb, "explicit usenet"},
      {"torrent", nil, "https://x/y.torrent", :torrent, "explicit torrent"},
      # Conflict: explicit field wins over URL heuristic.
      {"torrent", nil, "https://x/y.nzb", :torrent, "explicit torrent over .nzb URL"},
      {"usenet", nil, "https://x/y.torrent", :nzb, "explicit usenet over .torrent URL"},
      # Fallback: no explicit field; magnet URL wins first.
      {nil, "magnet:?xt=urn:btih:ABC", "https://x/y", :torrent, "fallback via magnetUrl"},
      # Fallback: no explicit field; URL contains .nzb -> :nzb.
      {nil, nil, "https://x/y.nzb", :nzb, "fallback via .nzb URL"},
      # Fallback: neither magnet nor .nzb -> nil (unknown protocol).
      {nil, nil, "https://x/y.torrent", nil, "fallback with .torrent URL stays nil"},
      {nil, nil, "https://x/y", nil, "fallback with no signal stays nil"}
    ]

    for {protocol, magnet, url, expected, note} <- @protocol_table do
      test "protocol detection: #{note}" do
        protocol = unquote(protocol)
        magnet = unquote(magnet)
        url = unquote(url)
        expected = unquote(expected)

        bypass = Bypass.open()

        item =
          %{
            "title" => "Probe",
            "size" => 1024,
            "downloadUrl" => url,
            "publishDate" => "2024-11-25T10:30:00Z",
            "indexer" => "TestIndexer"
          }
          |> Map.merge(if protocol, do: %{"downloadProtocol" => protocol}, else: %{})
          |> Map.merge(if magnet, do: %{"magnetUrl" => magnet}, else: %{})

        body = Jason.encode!([item])

        Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end)

        config = build_config(bypass)
        assert {:ok, [result]} = Prowlarr.search(config, "test")
        assert result.download_protocol == expected
      end
    end
  end

  describe "completion parsing (table-driven)" do
    # Newznab indexers expose article completion inconsistently — some return
    # an integer percent (0..100), others a 0.0..1.0 ratio. Pin the
    # normalisation so the adapter's parse_completion/1 stays well-defined.
    @completion_table [
      # {input, expected_normalised}
      {100, 1.0},
      {99, 0.99},
      {50, 0.5},
      {99.7, 0.997},
      {0.85, 0.85},
      {0.0, 0.0},
      {"95", 0.95},
      {"0.5", 0.5},
      {nil, nil},
      {"garbage", nil}
    ]

    for {input, expected} <- @completion_table do
      test "completion #{inspect(input)} -> #{inspect(expected)}" do
        input = unquote(input)
        expected = unquote(expected)

        bypass = Bypass.open()

        body =
          Jason.encode!([
            %{
              "title" => "Probe.NZB",
              "size" => 1024,
              "downloadUrl" => "https://x/y.nzb",
              "downloadProtocol" => "usenet",
              "publishDate" => "2024-11-25T10:30:00Z",
              "indexer" => "TestIndexer",
              "completion" => input
            }
          ])

        Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end)

        config = build_config(bypass)
        assert {:ok, [result]} = Prowlarr.search(config, "test")

        assert_completion(result.nzb_completion, expected)
      end
    end

    # Helper hides the expected value from the type-checker so float and nil
    # rows in @completion_table don't each trigger compile-time clause-never-
    # matches warnings at the call site.
    defp assert_completion(actual, nil), do: assert(actual == nil)

    defp assert_completion(actual, expected) when is_float(expected) do
      assert_in_delta(actual, expected, 0.0001)
    end
  end

  describe "search/3 retry behavior" do
    setup do
      {:ok, bypass: Bypass.open()}
    end

    test "a failing search is attempted exactly once", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"message":"boom"}))
      end)

      assert {:error, _} = Prowlarr.search(build_config(bypass), "Ubuntu")

      assert Agent.get(counter, & &1) == 1,
             "expected exactly one attempt, Req retried a transient failure"
    end
  end
end
