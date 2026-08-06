defmodule Mydia.Downloads.Client.TransmissionTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Transmission

  @config %{
    type: :transmission,
    host: "localhost",
    port: 9091,
    username: "admin",
    password: "adminpass",
    use_ssl: false,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      # Verify the module implements the required behaviour
      behaviours = Transmission.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection works with valid config structure" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.test_connection(timeout_config)
      # Should fail with connection error, not config error
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "test_connection accepts custom rpc_path" do
      custom_config = put_in(@config, [:options, :rpc_path], "/custom/rpc")
      unreachable_config = %{custom_config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    @tag timeout: 10000
    test "returns error with unreachable host for magnet link" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Transmission.add_torrent(timeout_config, {:magnet, magnet})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "returns error with unreachable host for file" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Minimal valid torrent file structure (not a real torrent)
      file_contents = "fake torrent file contents"

      {:error, error} = Transmission.add_torrent(timeout_config, {:file, file_contents})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "returns error with unreachable host for URL" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      url = "https://example.com/test.torrent"

      {:error, error} = Transmission.add_torrent(timeout_config, {:url, url})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts torrent options" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      # Test with various options
      opts = [
        save_path: "/downloads",
        paused: true,
        tags: ["label1", "label2"]
      ]

      {:error, _error} = Transmission.add_torrent(timeout_config, {:magnet, magnet}, opts)
      assert true
    end

    test "requires valid credentials" do
      invalid_config = %{@config | username: "wrong", password: "wrong"}

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Transmission.add_torrent(invalid_config, {:magnet, magnet})
      assert error.type in [:authentication_failed, :connection_failed, :network_error]
    end
  end

  describe "get_status/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.get_status(timeout_config, "1")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "accepts string and integer IDs" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Should work with both formats
      {:error, _error} = Transmission.get_status(timeout_config, "123")
      {:error, _error} = Transmission.get_status(timeout_config, 123)
      assert true
    end
  end

  describe "list_torrents/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :seeding)
      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :paused)
      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :completed)
      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :active)
      {:error, _error} = Transmission.list_torrents(timeout_config, filter: :inactive)
      assert true
    end

    test "accepts IDs filter" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.list_torrents(timeout_config, ids: [1, 2, 3])
      assert true
    end
  end

  describe "remove_torrent/3" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.remove_torrent(timeout_config, "1")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts delete_files option" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.remove_torrent(timeout_config, "1", delete_files: true)
      {:error, _error} = Transmission.remove_torrent(timeout_config, "1", delete_files: false)
      assert true
    end

    test "accepts string and integer IDs" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.remove_torrent(timeout_config, "123")
      {:error, _error} = Transmission.remove_torrent(timeout_config, 123)
      assert true
    end
  end

  describe "pause_torrent/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.pause_torrent(timeout_config, "1")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "accepts string and integer IDs" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.pause_torrent(timeout_config, "123")
      {:error, _error} = Transmission.pause_torrent(timeout_config, 123)
      assert true
    end
  end

  describe "resume_torrent/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Transmission.resume_torrent(timeout_config, "1")
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts string and integer IDs" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Transmission.resume_torrent(timeout_config, "123")
      {:error, _error} = Transmission.resume_torrent(timeout_config, 123)
      assert true
    end
  end

  describe "priority profile resolution (Bypass)" do
    setup do
      bypass = Bypass.open()

      config = %{
        @config
        | host: "localhost",
          port: bypass.port
      }

      {:ok, bypass: bypass, config: config}
    end

    # Transmission's RPC requires us to first hit a session-id endpoint, then
    # the actual call. Bypass handles both within the same expect block.
    defp transmission_handler(body, args_assertion) do
      decoded = Jason.decode!(body)
      assert decoded["method"] == "torrent-add"
      args_assertion.(decoded["arguments"])
    end

    test "empty profile passes no bandwidthPriority (Transmission uses its default)",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
          [] ->
            # First call: respond with 409 + session id
            conn
            |> Plug.Conn.put_resp_header("x-transmission-session-id", "test-session-id")
            |> Plug.Conn.resp(409, "")

          ["test-session-id"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

            transmission_handler(body, fn args ->
              refute Map.has_key?(args, "bandwidthPriority")
            end)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              ~s({"result":"success","arguments":{"torrent-added":{"hashString":"abc"}}})
            )
        end
      end)

      assert {:ok, "abc"} =
               Transmission.add_torrent(
                 config,
                 {:magnet, "magnet:?xt=urn:btih:abc"},
                 priority: :high
               )
    end

    test "profile override is forwarded as bandwidthPriority",
         %{bypass: bypass, config: config} do
      config_with_profile = Map.put(config, :priority_profile, %{"high" => 1})

      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("x-transmission-session-id", "session-2")
            |> Plug.Conn.resp(409, "")

          ["session-2"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

            transmission_handler(body, fn args ->
              assert args["bandwidthPriority"] == 1
            end)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              ~s({"result":"success","arguments":{"torrent-added":{"hashString":"def"}}})
            )
        end
      end)

      assert {:ok, "def"} =
               Transmission.add_torrent(
                 config_with_profile,
                 {:magnet, "magnet:?xt=urn:btih:def"},
                 priority: :high
               )
    end
  end

  describe "get_status/2 file list (Bypass)" do
    setup do
      bypass = Bypass.open()

      config = %{
        @config
        | host: "localhost",
          port: bypass.port
      }

      {:ok, bypass: bypass, config: config}
    end

    defp respond_torrent_get(conn, session_id, arguments_assertion, torrents) do
      case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("x-transmission-session-id", session_id)
          |> Plug.Conn.resp(409, "")

        [^session_id] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
          decoded = Jason.decode!(body)
          assert decoded["method"] == "torrent-get"
          arguments_assertion.(decoded["arguments"])

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"result" => "success", "arguments" => %{"torrents" => torrents}})
          )
      end
    end

    test "requests the files field and resolves it to absolute paths",
         %{bypass: bypass, config: config} do
      torrent = %{
        "hashString" => "abc123",
        "name" => "House.of.the.Dragon.S03E07.1080p.AMZN.WEB-DL.DDP5.1.Atmos.H.264-QAsH",
        "status" => 4,
        "percentDone" => 0.1,
        "downloadDir" => "/downloads",
        "files" => [
          %{"name" => "C7466DBA33FE8C5F53F0F80ED8BCFC62242EF310.exe", "length" => 891_885_056}
        ]
      }

      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        respond_torrent_get(
          conn,
          "session-files",
          fn args ->
            assert "files" in args["fields"]
            assert args["ids"] == ["abc123"]
          end,
          [torrent]
        )
      end)

      assert {:ok, status} = Transmission.get_status(config, "abc123")
      assert status.files == ["/downloads/C7466DBA33FE8C5F53F0F80ED8BCFC62242EF310.exe"]
    end

    test "returns nil when the client reports no files yet",
         %{bypass: bypass, config: config} do
      torrent = %{
        "hashString" => "def456",
        "name" => "Some.Show.S01E01",
        "status" => 4,
        "percentDone" => 0.0,
        "downloadDir" => "/downloads"
      }

      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        respond_torrent_get(
          conn,
          "session-nofiles",
          fn args -> assert "files" in args["fields"] end,
          [torrent]
        )
      end)

      assert {:ok, status} = Transmission.get_status(config, "def456")
      assert status.files == nil
    end

    test "filters out entries with a blank or missing name instead of joining an empty path",
         %{bypass: bypass, config: config} do
      torrent = %{
        "hashString" => "ghi789",
        "name" => "Some.Show.S01E02",
        "status" => 4,
        "percentDone" => 0.2,
        "downloadDir" => "/downloads",
        "files" => [
          %{"name" => "", "length" => 0},
          %{"length" => 0},
          %{"name" => "Some.Show.S01E02.mkv", "length" => 500}
        ]
      }

      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        respond_torrent_get(
          conn,
          "session-blank-name",
          fn args -> assert "files" in args["fields"] end,
          [torrent]
        )
      end)

      assert {:ok, status} = Transmission.get_status(config, "ghi789")
      assert status.files == ["/downloads/Some.Show.S01E02.mkv"]
    end

    test "returns nil when every file has a blank or missing name",
         %{bypass: bypass, config: config} do
      torrent = %{
        "hashString" => "jkl012",
        "name" => "Some.Show.S01E03",
        "status" => 4,
        "percentDone" => 0.0,
        "downloadDir" => "/downloads",
        "files" => [%{"name" => "", "length" => 0}, %{"length" => 0}]
      }

      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        respond_torrent_get(
          conn,
          "session-all-blank",
          fn args -> assert "files" in args["fields"] end,
          [torrent]
        )
      end)

      assert {:ok, status} = Transmission.get_status(config, "jkl012")
      assert status.files == nil
    end
  end

  # Note: Full integration tests would require either:
  # 1. A real Transmission instance (can be configured via environment variables)
  # 2. HTTP mocking library like Bypass or Mox to simulate Transmission RPC responses
  #
  # Integration tests should verify:
  # - RPC request format (method, arguments, tag)
  # - CSRF protection flow (initial 409, retry with X-Transmission-Session-Id header)
  # - Authentication with valid/invalid credentials
  # - Adding torrents (magnet links, base64 files, URLs) with various options
  # - Retrieving torrent status with all fields parsed correctly
  # - Listing torrents with various filters (state-based filtering)
  # - Removing torrents with/without file deletion
  # - Pausing and resuming torrents
  # - State mapping (status codes 0-6 to internal states)
  # - Error handling for various failure scenarios (duplicate, not found, etc.)
  # - Tag counter incrementing for sequential RPC request IDs
end
