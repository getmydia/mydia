defmodule Mydia.Downloads.Client.QBittorrentTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.QBittorrent

  @config %{
    type: :qbittorrent,
    host: "localhost",
    port: 8080,
    username: "admin",
    password: "adminpass",
    use_ssl: false,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      # Verify the module implements the required behaviour
      behaviours = QBittorrent.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection requires username and password" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = QBittorrent.test_connection(config_without_username)
      assert error.type == :invalid_config
      assert error.message =~ "Username and password are required"
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = QBittorrent.add_torrent(timeout_config, {:magnet, magnet})
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "requires valid credentials" do
      invalid_config = %{@config | username: "wrong", password: "wrong"}

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = QBittorrent.add_torrent(invalid_config, {:magnet, magnet})
      assert error.type in [:authentication_failed, :connection_failed, :network_error]
    end
  end

  describe "get_status/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.get_status(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  describe "list_torrents/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      # Actual filtering would be tested in integration tests
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = QBittorrent.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = QBittorrent.list_torrents(timeout_config, category: "test")
      {:error, _error} = QBittorrent.list_torrents(timeout_config, tag: "test")
      assert true
    end
  end

  describe "remove_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.remove_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "accepts delete_files option" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} =
        QBittorrent.remove_torrent(timeout_config, "somehash", delete_files: true)

      {:error, _error} =
        QBittorrent.remove_torrent(timeout_config, "somehash", delete_files: false)

      assert true
    end
  end

  describe "pause_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.pause_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  describe "resume_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = QBittorrent.resume_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Bypass-based integration tests
  # ──────────────────────────────────────────────────────────────────

  # Login dialects observed from real servers.
  # 5.1.2 -> 200 "Ok."  + SID=<v>
  # 5.2.0 -> 204 ""     + QBT_SID_<webui_port>=<v>
  # The 5.2 cookie's port (8080) is deliberately NOT the port Bypass listens on,
  # which is what makes the echo assertion meaningful: the name cannot be
  # reconstructed from our config, it must be read off Set-Cookie.
  @dialects [
    {"5.1", 200, "Ok.", "SID=session-abc-123; HttpOnly; SameSite=Strict; path=/",
     "SID=session-abc-123"},
    {"5.2", 204, "",
     "QBT_SID_8080=session-abc-123; HttpOnly; SameSite=Strict; " <>
       "expires=Wed, 29-Jul-2026 01:06:04 GMT; path=/", "QBT_SID_8080=session-abc-123"}
  ]

  describe "authentication (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "extracts SID cookie even when multiple Set-Cookie headers are present", %{
      bypass: bypass,
      config: config
    } do
      hash = "1234567890abcdef1234567890abcdef12345678"

      Bypass.expect(bypass, "POST", "/api/v2/auth/login", fn conn ->
        # Real qBittorrent sometimes sets a CSRF cookie alongside SID.
        # We must pick the SID cookie, not the first one.
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "_csrf=ignored; Path=/")
        |> Plug.Conn.merge_resp_headers([
          {"set-cookie", "SID=session-abc-123; HttpOnly; Path=/"}
        ])
        |> Plug.Conn.resp(200, "Ok.")
      end)

      Bypass.expect(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        # The request must carry our SID, not the _csrf cookie.
        assert ["SID=session-abc-123"] = Plug.Conn.get_req_header(conn, "cookie")
        json_resp(conn, 200, [torrent_payload(hash)])
      end)

      assert {:ok, status} = QBittorrent.get_status(config, hash)
      assert status.id == hash
    end

    test "re-authenticates on 403 and retries the original request", %{
      bypass: bypass,
      config: config
    } do
      hash = "abc123def456abc123def456abc123def456abcd"
      counter = :counters.new(2, [])

      Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "SID=fresh-sid; HttpOnly")
        |> Plug.Conn.resp(200, "Ok.")
      end)

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        :counters.add(counter, 2, 1)
        n = :counters.get(counter, 2)

        if n == 1 do
          Plug.Conn.resp(conn, 403, "Forbidden")
        else
          json_resp(conn, 200, [torrent_payload(hash)])
        end
      end)

      assert {:ok, _status} = QBittorrent.get_status(config, hash)
      # Two logins: one initial, one after the 403
      assert :counters.get(counter, 1) == 2
    end

    for {version, login_status, login_body, set_cookie, expected_cookie} <- @dialects do
      test "authenticates and echoes the session cookie on qBittorrent #{version}", %{
        bypass: bypass,
        config: config
      } do
        hash = "1234567890abcdef1234567890abcdef12345678"

        Bypass.expect(bypass, "POST", "/api/v2/auth/login", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", unquote(set_cookie))
          |> Plug.Conn.resp(unquote(login_status), unquote(login_body))
        end)

        Bypass.expect(bypass, "GET", "/api/v2/torrents/info", fn conn ->
          assert [unquote(expected_cookie)] == Plug.Conn.get_req_header(conn, "cookie")
          json_resp(conn, 200, [torrent_payload(hash)])
        end)

        assert {:ok, download_status} = QBittorrent.get_status(config, hash)
        assert download_status.id == hash
      end

      test "skips the _csrf cookie on qBittorrent #{version}", %{
        bypass: bypass,
        config: config
      } do
        hash = "1234567890abcdef1234567890abcdef12345678"

        Bypass.expect(bypass, "POST", "/api/v2/auth/login", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "_csrf=ignored; Path=/")
          |> Plug.Conn.merge_resp_headers([{"set-cookie", unquote(set_cookie)}])
          |> Plug.Conn.resp(unquote(login_status), unquote(login_body))
        end)

        Bypass.expect(bypass, "GET", "/api/v2/torrents/info", fn conn ->
          assert [unquote(expected_cookie)] == Plug.Conn.get_req_header(conn, "cookie")
          json_resp(conn, 200, [torrent_payload(hash)])
        end)

        assert {:ok, _} = QBittorrent.get_status(config, hash)
      end
    end
  end

  describe "add_torrent/3 (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "uploads .torrent files via multipart/form-data, not urlencoded", %{
      bypass: bypass,
      config: config
    } do
      torrent_binary = sample_torrent_file()
      {:ok, hash} = Mydia.Downloads.TorrentHash.extract({:file, torrent_binary}, case: :lower)

      stub_login(bypass)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/add", fn conn ->
        # qBittorrent requires multipart/form-data when uploading a torrent file.
        # If we send urlencoded, the binary is corrupted and the torrent is silently dropped.
        [content_type | _] = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type =~ "multipart/form-data"

        # Verify the body actually contains the torrent payload (the bencoded "d8:announce"
        # marker is present in our sample fixture).
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "8:announce"

        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      # Post-add verification: the adapter should poll info?hashes=<h> to confirm presence.
      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash)])
      end)

      assert {:ok, returned_hash} = QBittorrent.add_torrent(config, {:file, torrent_binary})
      assert returned_hash == hash
    end

    test "verifies the torrent was actually added before returning success", %{
      bypass: bypass,
      config: config
    } do
      magnet = "magnet:?xt=urn:btih:abc123def456abc123def456abc123def456abcd&dn=test"

      stub_login(bypass)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/add", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      # qBittorrent says "Ok." but the torrent never appears in info — should error,
      # not silently create a phantom DB record.
      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [])
      end)

      assert {:error, error} = QBittorrent.add_torrent(config, {:magnet, magnet})
      assert error.type == :api_error
      assert error.message =~ "not present in qBittorrent" or error.message =~ "rejected"
    end

    test "tolerates qBittorrent indexing delay (eventually appears in info)", %{
      bypass: bypass,
      config: config
    } do
      magnet = "magnet:?xt=urn:btih:abc123def456abc123def456abc123def456abcd&dn=test"
      hash = "abc123def456abc123def456abc123def456abcd"

      stub_login(bypass)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/add", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      # First poll returns empty (still indexing), second returns the torrent.
      counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n >= 2 do
          json_resp(conn, 200, [torrent_payload(hash)])
        else
          json_resp(conn, 200, [])
        end
      end)

      assert {:ok, ^hash} = QBittorrent.add_torrent(config, {:magnet, magnet})
    end
  end

  describe "state mapping (Bypass)" do
    setup do
      bypass = Bypass.open()
      stub_login(bypass)
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "maps qBittorrent 5.x stoppedDL/stoppedUP to :paused", %{
      bypass: bypass,
      config: config
    } do
      hash = "5xstop00000000000000000000000000stopped5"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "stoppedDL")])
      end)

      assert {:ok, %{state: :paused}} = QBittorrent.get_status(config, hash)
    end

    test "maps qBittorrent 5.x stoppedUP to :paused (post-completion)", %{
      bypass: bypass,
      config: config
    } do
      hash = "5xstop00000000000000000000000000stoppedu"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "stoppedUP")])
      end)

      assert {:ok, %{state: :paused}} = QBittorrent.get_status(config, hash)
    end

    test "maps moving state to :checking (transient, not an error)", %{
      bypass: bypass,
      config: config
    } do
      hash = "moving00000000000000000000000000000move0"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "moving")])
      end)

      assert {:ok, %{state: :checking}} = QBittorrent.get_status(config, hash)
    end

    test "maps unknown state to :checking (transient), not :error", %{
      bypass: bypass,
      config: config
    } do
      hash = "unknown00000000000000000000000000unknown"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "unknown")])
      end)

      assert {:ok, %{state: :checking}} = QBittorrent.get_status(config, hash)
    end

    test "maps unmapped/future state names to :checking, not :error", %{
      bypass: bypass,
      config: config
    } do
      # Defensive: a future qBittorrent state we don't know about should not
      # cause DownloadMonitor to delete the row (which it does on :error).
      hash = "future00000000000000000000000000future00"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "someBrandNewState")])
      end)

      assert {:ok, %{state: :checking}} = QBittorrent.get_status(config, hash)
    end

    test "preserves :error for real error states", %{bypass: bypass, config: config} do
      hash = "error00000000000000000000000000000error0"

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash, state: "error")])
      end)

      assert {:ok, %{state: :error}} = QBittorrent.get_status(config, hash)
    end
  end

  describe "pause/resume routing (Bypass)" do
    setup do
      bypass = Bypass.open()
      stub_login(bypass)
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "pause hits the legacy /pause endpoint by default", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/api/v2/torrents/pause", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      assert :ok = QBittorrent.pause_torrent(config, "somehash")
    end

    test "resume hits the legacy /resume endpoint by default", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/api/v2/torrents/resume", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      assert :ok = QBittorrent.resume_torrent(config, "somehash")
    end

    test "pause falls back to /stop on 404 (qBittorrent 5.x)", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/api/v2/torrents/pause", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/stop", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      assert :ok = QBittorrent.pause_torrent(config, "somehash")
    end

    test "resume falls back to /start on 404 (qBittorrent 5.x)", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/api/v2/torrents/resume", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/start", fn conn ->
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      assert :ok = QBittorrent.resume_torrent(config, "somehash")
    end
  end

  describe "priority profile resolution (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    # qBittorrent's `/api/v2/torrents/add` endpoint has no priority field, so
    # the adapter's documented behaviour is to silently accept the option
    # without forwarding it. Both branches (empty profile + override) should
    # succeed and not surface any priority key in the form body.
    test "empty profile: :priority is accepted but not forwarded",
         %{bypass: bypass, config: config} do
      torrent_binary = sample_torrent_file()
      {:ok, hash} = Mydia.Downloads.TorrentHash.extract({:file, torrent_binary}, case: :lower)

      stub_login(bypass)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/add", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        # No qBittorrent priority parameter is supported on add — verify we
        # didn't accidentally inject one.
        refute body =~ "bandwidthPriority"
        refute body =~ ~r/name="priority"/

        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash)])
      end)

      assert {:ok, ^hash} =
               QBittorrent.add_torrent(config, {:file, torrent_binary},
                 priority: :high,
                 title: "Test"
               )
    end

    test "profile override: :priority is accepted, logged, but not forwarded",
         %{bypass: bypass, config: config} do
      torrent_binary = sample_torrent_file()
      {:ok, hash} = Mydia.Downloads.TorrentHash.extract({:file, torrent_binary}, case: :lower)

      config_with_profile = Map.put(config, :priority_profile, %{"high" => 7})

      stub_login(bypass)

      Bypass.expect(bypass, "POST", "/api/v2/torrents/add", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        refute body =~ "bandwidthPriority"
        Plug.Conn.resp(conn, 200, "Ok.")
      end)

      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, [torrent_payload(hash)])
      end)

      assert {:ok, ^hash} =
               QBittorrent.add_torrent(config_with_profile, {:file, torrent_binary},
                 priority: :high,
                 title: "Test"
               )
    end
  end

  ## Helpers

  defp bypass_config(bypass) do
    %{
      type: :qbittorrent,
      host: "localhost",
      port: bypass.port,
      username: "admin",
      password: "adminpass",
      use_ssl: false,
      options: %{timeout: 5_000, connect_timeout: 2_000, post_add_poll_attempts: 3}
    }
  end

  defp stub_login(bypass) do
    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp torrent_payload(hash, overrides \\ []) do
    Map.merge(
      %{
        "hash" => hash,
        "name" => "Test Torrent",
        "state" => "downloading",
        "progress" => 0.5,
        "dlspeed" => 100_000,
        "upspeed" => 0,
        "downloaded" => 500,
        "uploaded" => 0,
        "size" => 1000,
        "eta" => 60,
        "ratio" => 0.0,
        "save_path" => "/downloads",
        "added_on" => 1_700_000_000,
        "completion_on" => -1
      },
      Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
    )
  end

  # Minimal valid bencoded torrent metainfo for testing the upload path.
  # The info dict only needs to be structurally valid bencode; the hash is
  # computed by SHA1 of the bencoded info dict regardless of contents.
  defp sample_torrent_file do
    info_dict =
      "d6:lengthi100e4:name8:test.bin12:piece lengthi16384e6:pieces20:" <>
        :binary.copy(<<0>>, 20) <> "e"

    "d8:announce20:http://tracker.test/4:info" <> info_dict <> "e"
  end
end
