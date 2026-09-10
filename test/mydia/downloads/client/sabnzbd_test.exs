defmodule Mydia.Downloads.Client.SabnzbdTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Sabnzbd
  alias Mydia.Downloads.Structs.{ClientInfo, DownloadStatus}

  @config %{
    type: :sabnzbd,
    host: "localhost",
    port: 8080,
    api_key: "test-api-key",
    use_ssl: false,
    url_base: nil,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      # Verify the module implements the required behaviour
      behaviours = Sabnzbd.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection requires API key" do
      config_without_api_key = Map.delete(@config, :api_key)

      {:error, error} = Sabnzbd.test_connection(config_without_api_key)
      assert error.type == :invalid_config
      assert error.message =~ "API key is required"
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    test "returns error with unreachable host for URL addition" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      nzb_url = "https://example.com/test.nzb"

      {:error, error} = Sabnzbd.add_torrent(timeout_config, {:url, nzb_url})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "rejects magnet links" do
      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Sabnzbd.add_torrent(@config, {:magnet, magnet})
      assert error.type == :invalid_torrent
      assert error.message =~ "does not support magnet links"
    end

    test "requires API key" do
      config_without_api_key = Map.delete(@config, :api_key)
      nzb_url = "https://example.com/test.nzb"

      {:error, error} = Sabnzbd.add_torrent(config_without_api_key, {:url, nzb_url})
      assert error.type == :invalid_config
    end
  end

  describe "get_status/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.get_status(timeout_config, "SABnzbd_nzo_test123")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "list_torrents/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Sabnzbd.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = Sabnzbd.list_torrents(timeout_config, filter: :completed)
      {:error, _error} = Sabnzbd.list_torrents(timeout_config, filter: :paused)
      assert true
    end
  end

  describe "remove_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.remove_torrent(timeout_config, "SABnzbd_nzo_test123")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires API key" do
      config_without_api_key = Map.delete(@config, :api_key)

      {:error, error} = Sabnzbd.remove_torrent(config_without_api_key, "SABnzbd_nzo_test123")
      assert error.type == :invalid_config
    end

    test "accepts delete_files option" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Sabnzbd.remove_torrent(timeout_config, "test", delete_files: true)
      {:error, _error} = Sabnzbd.remove_torrent(timeout_config, "test", delete_files: false)
      assert true
    end
  end

  describe "pause_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.pause_torrent(timeout_config, "SABnzbd_nzo_test123")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires API key" do
      config_without_api_key = Map.delete(@config, :api_key)

      {:error, error} = Sabnzbd.pause_torrent(config_without_api_key, "SABnzbd_nzo_test123")
      assert error.type == :invalid_config
    end
  end

  describe "resume_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Sabnzbd.resume_torrent(timeout_config, "SABnzbd_nzo_test123")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "requires API key" do
      config_without_api_key = Map.delete(@config, :api_key)

      {:error, error} = Sabnzbd.resume_torrent(config_without_api_key, "SABnzbd_nzo_test123")
      assert error.type == :invalid_config
    end
  end

  describe "state mapping" do
    # See "state taxonomy (Bypass + table-driven)" and "fixture-based parsing
    # (Bypass)" below for the full coverage. `parse_state/1` is private, so
    # mapping is asserted through the public `list_torrents/2` path with a
    # one-slot fixture per status string.
  end

  describe "URL base handling" do
    test "handles custom URL base in configuration" do
      config_with_base = %{@config | url_base: "/sabnzbd"}
      unreachable_config = %{config_with_base | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Should fail with connection error, not path error
      {:error, error} = Sabnzbd.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "strips a trailing slash from url_base (#765)" do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port, url_base: "/sabnzbd/"}
      Mydia.BypassHelpers.stub_exact_json(bypass, "GET", "/sabnzbd/api", ~s({"version": "4.3.2"}))

      assert {:ok, %ClientInfo{version: "4.3.2"}} = Sabnzbd.test_connection(config)
    end

    test "treats a url_base of \"/\" as no base (#765)" do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port, url_base: "/"}
      Mydia.BypassHelpers.stub_exact_json(bypass, "GET", "/api", ~s({"version": "4.3.2"}))

      assert {:ok, %ClientInfo{version: "4.3.2"}} = Sabnzbd.test_connection(config)
    end
  end

  describe "add_torrent/3 with Bypass" do
    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    test "sends title-based multipart filename and nzbname param for file upload",
         %{bypass: bypass, config: config} do
      nzb_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nzb></nzb>"

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["nzbname"] == "Movie Name (2024)"

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "Movie Name (2024).nzb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_test123"]}))
      end)

      assert {:ok, "SABnzbd_nzo_test123"} =
               Sabnzbd.add_torrent(config, {:file, nzb_content}, title: "Movie Name (2024)")
    end

    test "sends nzbname param for URL addition", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["nzbname"] == "Show S01E01"
        assert conn.query_params["mode"] == "addurl"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_test456"]}))
      end)

      assert {:ok, "SABnzbd_nzo_test456"} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"},
                 title: "Show S01E01"
               )
    end

    test "falls back to upload.nzb when no title provided for file upload",
         %{bypass: bypass, config: config} do
      nzb_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nzb></nzb>"

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "nzbname")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "upload.nzb"
        refute body =~ "nil"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_test789"]}))
      end)

      assert {:ok, "SABnzbd_nzo_test789"} =
               Sabnzbd.add_torrent(config, {:file, nzb_content})
    end

    test "falls back to upload.nzb when title is nil for file upload",
         %{bypass: bypass, config: config} do
      nzb_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nzb></nzb>"

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "nzbname")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "upload.nzb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_nil"]}))
      end)

      assert {:ok, "SABnzbd_nzo_nil"} =
               Sabnzbd.add_torrent(config, {:file, nzb_content}, title: nil)
    end

    test "falls back to upload.nzb and omits nzbname when title is empty",
         %{bypass: bypass, config: config} do
      nzb_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nzb></nzb>"

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "nzbname")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "upload.nzb"
        refute body =~ ".nzb\"; filename=\".nzb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_empty"]}))
      end)

      assert {:ok, "SABnzbd_nzo_empty"} =
               Sabnzbd.add_torrent(config, {:file, nzb_content}, title: "")
    end

    test "sanitizes invalid filename characters for file upload title",
         %{bypass: bypass, config: config} do
      nzb_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nzb></nzb>"

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["nzbname"] == "Movie: Name/2024?"

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "Movie_ Name_2024_.nzb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_sanitized"]}))
      end)

      assert {:ok, "SABnzbd_nzo_sanitized"} =
               Sabnzbd.add_torrent(config, {:file, nzb_content}, title: "Movie: Name/2024?")
    end

    test "no nzbname param when no title for URL addition",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "nzbname")
        assert conn.query_params["mode"] == "addurl"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_url"]}))
      end)

      assert {:ok, "SABnzbd_nzo_url"} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"})
    end

    test "no nzbname param when title is empty string for URL addition",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "nzbname")
        assert conn.query_params["mode"] == "addurl"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_url_empty"]}))
      end)

      assert {:ok, "SABnzbd_nzo_url_empty"} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"}, title: "")
    end
  end

  describe "priority profile resolution (Bypass)" do
    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    test "empty profile falls back to hardcoded :high -> \"1\"",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["priority"] == "1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_p"]}))
      end)

      assert {:ok, "SABnzbd_nzo_p"} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"},
                 priority: :high
               )
    end

    test "empty profile falls back to hardcoded :low -> \"-1\"",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["priority"] == "-1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_low"]}))
      end)

      assert {:ok, "SABnzbd_nzo_low"} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"}, priority: :low)
    end

    test "empty profile maps the new tier :verylow -> \"-100\"",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["priority"] == "-100"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_vl"]}))
      end)

      assert {:ok, _} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"},
                 priority: :verylow
               )
    end

    test "empty profile maps the new tier :veryhigh -> \"2\"",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["priority"] == "2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_vh"]}))
      end)

      assert {:ok, _} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"},
                 priority: :veryhigh
               )
    end

    test "profile override wins over hardcoded default",
         %{bypass: bypass, config: config} do
      config_with_profile = Map.put(config, :priority_profile, %{"high" => "2"})

      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        # :high resolves to "2" via the profile, not the hardcoded "1"
        assert conn.query_params["priority"] == "2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_o"]}))
      end)

      assert {:ok, _} =
               Sabnzbd.add_torrent(config_with_profile, {:url, "https://example.com/test.nzb"},
                 priority: :high
               )
    end

    test "tier not present in profile falls back to its hardcoded default",
         %{bypass: bypass, config: config} do
      # Profile only overrides :high; :low must still resolve to "-1".
      config_with_profile = Map.put(config, :priority_profile, %{"high" => "2"})

      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["priority"] == "-1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_fb"]}))
      end)

      assert {:ok, _} =
               Sabnzbd.add_torrent(config_with_profile, {:url, "https://example.com/test.nzb"},
                 priority: :low
               )
    end

    test "nil priority omits the priority param entirely",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "priority")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": true, "nzo_ids": ["SABnzbd_nzo_npr"]}))
      end)

      assert {:ok, _} =
               Sabnzbd.add_torrent(config, {:url, "https://example.com/test.nzb"})
    end
  end

  describe "fixture-based parsing (Bypass)" do
    # Path: test/mydia/downloads/client -> ../../../support/fixtures
    @queue_fixture Path.expand("../../../support/fixtures/sabnzbd/queue.json", __DIR__)
    @history_fixture Path.expand("../../../support/fixtures/sabnzbd/history.json", __DIR__)

    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}

      queue_body = File.read!(@queue_fixture)
      history_body = File.read!(@history_fixture)

      {:ok, bypass: bypass, config: config, queue_body: queue_body, history_body: history_body}
    end

    # Routes the canonical queue + history Bypass response based on the
    # `mode` query param so list_torrents/2 sees a realistic two-step fetch.
    defp expect_queue_and_history(bypass, queue_body, history_body) do
      Bypass.expect(bypass, "GET", "/api", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        body = if conn.query_params["mode"] == "history", do: history_body, else: queue_body

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)
    end

    test "list_torrents parses every queue + history fixture slot into DownloadStatus",
         %{bypass: bypass, config: config, queue_body: queue_body, history_body: history_body} do
      expect_queue_and_history(bypass, queue_body, history_body)

      assert {:ok, statuses} = Sabnzbd.list_torrents(config)
      assert length(statuses) == 9

      assert Enum.all?(statuses, &match?(%DownloadStatus{}, &1))

      # Sanity-check the first downloading slot: fields drawn straight from
      # the queue fixture survive the parse intact.
      dl = Enum.find(statuses, &(&1.id == "SABnzbd_nzo_dl001"))
      assert dl.name == "Show.S01E01.1080p.WEB-DL.x264-GROUP"
      assert dl.state == :downloading
      assert_in_delta dl.progress, 50.0, 0.5
      # 2048 MiB total, 1024 MiB left -> 1024 MiB downloaded
      assert dl.size == 2_048 * 1_048_576
      assert dl.downloaded == 1_024 * 1_048_576
      # kbpersec 7680.0 -> bytes per second
      assert dl.download_speed == round(7680.0 * 1024)
      # 0:02:15
      assert dl.eta == 135
      assert dl.save_path == "/downloads/incomplete"
      assert dl.added_at == ~U[2023-11-14 22:13:20Z]
      assert dl.completed_at == nil
    end

    test "queue status strings map onto the canonical state taxonomy",
         %{bypass: bypass, config: config, queue_body: queue_body, history_body: history_body} do
      expect_queue_and_history(bypass, queue_body, history_body)

      assert {:ok, statuses} = Sabnzbd.list_torrents(config)
      by_id = Map.new(statuses, &{&1.id, &1.state})

      # The 2026-04-08 fix moved Extracting/Moving from :error to :checking so
      # the DownloadMonitor doesn't prematurely flag in-flight post-processing
      # as missing. Pin both here so a regression is caught at this layer.
      assert by_id["SABnzbd_nzo_dl001"] == :downloading
      assert by_id["SABnzbd_nzo_ps002"] == :paused
      # Queued is folded into :downloading per the SABnzbd adapter docstring.
      assert by_id["SABnzbd_nzo_q0003"] == :downloading
      assert by_id["SABnzbd_nzo_vf004"] == :checking
      assert by_id["SABnzbd_nzo_ex005"] == :checking
      assert by_id["SABnzbd_nzo_mv006"] == :checking
    end

    test "history Completed/Failed slots produce :completed/:error states",
         %{bypass: bypass, config: config, queue_body: queue_body, history_body: history_body} do
      expect_queue_and_history(bypass, queue_body, history_body)

      assert {:ok, statuses} = Sabnzbd.list_torrents(config)
      by_id = Map.new(statuses, &{&1.id, &1})

      done = by_id["SABnzbd_nzo_done01"]
      assert done.state == :completed
      # SABnzbd history slots expose the title as `name`, not `filename`. The
      # adapter currently only reads `filename`, so the name field is empty
      # for history items. Pinning the actual behaviour here so a future fix
      # that also picks up `name` is caught.
      assert done.name == ""
      # History reports size in bytes under `size`, not MiB
      assert done.size == 2_147_483_648
      assert done.save_path == "/downloads/complete/tv/Completed.Show"
      assert done.completed_at == ~U[2023-11-15 12:06:40Z]

      failed = by_id["SABnzbd_nzo_fail02"]
      assert failed.state == :error
      assert failed.size == 8_589_934_592
      # Non-completed history slots: completed_at is left nil
      assert failed.completed_at == nil
    end

    test "list_torrents filter: :downloading keeps Downloading/Fetching/Queued only",
         %{bypass: bypass, config: config, queue_body: queue_body, history_body: history_body} do
      expect_queue_and_history(bypass, queue_body, history_body)

      assert {:ok, statuses} = Sabnzbd.list_torrents(config, filter: :downloading)
      ids = Enum.map(statuses, & &1.id) |> MapSet.new()

      assert MapSet.equal?(ids, MapSet.new(["SABnzbd_nzo_dl001", "SABnzbd_nzo_q0003"]))
    end

    test "list_torrents filter: :completed keeps history Completed slots",
         %{bypass: bypass, config: config, queue_body: queue_body, history_body: history_body} do
      expect_queue_and_history(bypass, queue_body, history_body)

      assert {:ok, statuses} = Sabnzbd.list_torrents(config, filter: :completed)
      ids = Enum.map(statuses, & &1.id) |> MapSet.new()

      assert MapSet.equal?(ids, MapSet.new(["SABnzbd_nzo_done01", "SABnzbd_nzo_done03"]))
    end
  end

  describe "state taxonomy (Bypass + table-driven)" do
    # Every SABnzbd queue status that the adapter recognises. Drives
    # parse_state/1 (private) through list_torrents/2 with a synthetic
    # single-slot queue per row. Covers the 2026-04-08 fix that re-routed
    # Extracting and Moving from :error to :checking.
    @state_table [
      {"Downloading", :downloading},
      {"Fetching", :downloading},
      {"Queued", :downloading},
      {"Paused", :paused},
      {"Completed", :completed},
      {"Failed", :error},
      {"Verifying", :checking},
      {"Repairing", :checking},
      {"Extracting", :checking},
      {"Moving", :checking},
      {"UnknownState", :error}
    ]

    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    for {sabnzbd_state, expected_state} <- @state_table do
      test "maps SABnzbd status #{inspect(sabnzbd_state)} to #{inspect(expected_state)}",
           %{bypass: bypass, config: config} do
        sabnzbd_state = unquote(sabnzbd_state)
        expected_state = unquote(expected_state)

        queue_body =
          Jason.encode!(%{
            "queue" => %{
              "slots" => [
                %{
                  "nzo_id" => "SABnzbd_nzo_state",
                  "filename" => "Probe",
                  "status" => sabnzbd_state,
                  "mb" => "100.0",
                  "mbleft" => "50.0",
                  "kbpersec" => "0.0",
                  "timeleft" => "0:00:00",
                  "storage" => "/tmp"
                }
              ]
            }
          })

        history_body = Jason.encode!(%{"history" => %{"slots" => []}})

        Bypass.expect(bypass, "GET", "/api", fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          body = if conn.query_params["mode"] == "history", do: history_body, else: queue_body

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end)

        assert {:ok, [%{state: ^expected_state}]} = Sabnzbd.list_torrents(config)
      end
    end
  end

  describe "ETA parsing edge cases (Bypass)" do
    setup do
      bypass = Bypass.open()
      config = %{@config | host: "localhost", port: bypass.port}
      {:ok, bypass: bypass, config: config}
    end

    # Drives the adapter's private parse_eta/1 through list_torrents/2. SABnzbd
    # returns ETA as HH:MM:SS strings; anything malformed must degrade to nil
    # rather than crash the parse pipeline.
    @eta_cases [
      {"0:00:00", 0},
      {"0:02:15", 135},
      {"99:59:59", 359_999},
      # Malformed / sentinel values: parse_eta is permissive and returns nil.
      {"", nil},
      {"-", nil},
      {"unknown", nil},
      {"not:a:time", nil}
    ]

    for {timeleft, expected_eta} <- @eta_cases do
      test "parses timeleft #{inspect(timeleft)} as eta=#{inspect(expected_eta)}",
           %{bypass: bypass, config: config} do
        timeleft = unquote(timeleft)
        expected_eta = unquote(expected_eta)

        queue_body =
          Jason.encode!(%{
            "queue" => %{
              "slots" => [
                %{
                  "nzo_id" => "SABnzbd_nzo_eta",
                  "filename" => "EtaProbe",
                  "status" => "Downloading",
                  "mb" => "100.0",
                  "mbleft" => "50.0",
                  "kbpersec" => "1024.0",
                  "timeleft" => timeleft,
                  "storage" => "/tmp"
                }
              ]
            }
          })

        history_body = Jason.encode!(%{"history" => %{"slots" => []}})

        Bypass.expect(bypass, "GET", "/api", fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          body = if conn.query_params["mode"] == "history", do: history_body, else: queue_body

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, body)
        end)

        assert {:ok, [%{eta: ^expected_eta}]} = Sabnzbd.list_torrents(config)
      end
    end
  end
end
