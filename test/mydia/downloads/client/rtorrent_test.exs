defmodule Mydia.Downloads.Client.RtorrentTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Rtorrent

  @config %{
    type: :rtorrent,
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
      behaviours = Rtorrent.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection works with valid config structure" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Rtorrent.test_connection(timeout_config)
      # Should fail with connection error, not config error
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Rtorrent.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "test_connection accepts custom rpc_path" do
      custom_config = put_in(@config, [:options, :rpc_path], "/XMLRPC")
      unreachable_config = %{custom_config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Rtorrent.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    @tag timeout: 10000
    test "returns error with unreachable host for magnet link" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Rtorrent.add_torrent(timeout_config, {:magnet, magnet})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "returns error with unreachable host for file" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      # Minimal valid torrent file structure (not a real torrent)
      file_contents = "fake torrent file contents"

      {:error, error} = Rtorrent.add_torrent(timeout_config, {:file, file_contents})
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "returns error with unreachable host for URL" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      url = "https://example.com/test.torrent"

      {:error, error} = Rtorrent.add_torrent(timeout_config, {:url, url})
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
        category: "test-category"
      ]

      {:error, _error} = Rtorrent.add_torrent(timeout_config, {:magnet, magnet}, opts)
      assert true
    end
  end

  describe "get_status/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} =
        Rtorrent.get_status(timeout_config, "ABC123DEF456789012345678901234567890ABCD")

      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "list_torrents/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Rtorrent.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    @tag timeout: 10000
    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Rtorrent.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = Rtorrent.list_torrents(timeout_config, filter: :seeding)
      {:error, _error} = Rtorrent.list_torrents(timeout_config, filter: :paused)
      {:error, _error} = Rtorrent.list_torrents(timeout_config, filter: :completed)
      {:error, _error} = Rtorrent.list_torrents(timeout_config, filter: :active)
      assert true
    end
  end

  describe "remove_torrent/3" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} =
        Rtorrent.remove_torrent(timeout_config, "ABC123DEF456789012345678901234567890ABCD")

      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "accepts delete_files option" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} =
        Rtorrent.remove_torrent(timeout_config, "ABC123DEF456789012345678901234567890ABCD",
          delete_files: true
        )

      {:error, _error} =
        Rtorrent.remove_torrent(timeout_config, "ABC123DEF456789012345678901234567890ABCD",
          delete_files: false
        )

      assert true
    end
  end

  describe "pause_torrent/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} =
        Rtorrent.pause_torrent(timeout_config, "ABC123DEF456789012345678901234567890ABCD")

      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "resume_torrent/2" do
    @tag timeout: 10000
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} =
        Rtorrent.resume_torrent(timeout_config, "ABC123DEF456789012345678901234567890ABCD")

      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "file scoping (Bypass)" do
    setup do
      bypass = Bypass.open()

      config = %{
        @config
        | host: "localhost",
          port: bypass.port,
          username: nil,
          password: nil
      }

      {:ok, bypass: bypass, config: config}
    end

    test "scopes a single-file torrent to d.base_path, not the shared directory",
         %{bypass: bypass, config: config} do
      hash = "ABC123DEF456789012345678901234567890ABCD"

      # For a single-file torrent d.directory is the *containing* download
      # root; d.base_path is the file itself. Recursively importing the former
      # sweeps in every neighbouring torrent.
      stub_multicall(bypass,
        hash: hash,
        directory: "/downloads",
        base_path: "/downloads/Silo.S03E02.1080p.mkv"
      )

      assert {:ok, status} = Rtorrent.get_status(config, hash)
      assert status.save_path == "/downloads"
      assert status.files == ["/downloads/Silo.S03E02.1080p.mkv"]
    end

    test "scopes a multi-file torrent to its own directory",
         %{bypass: bypass, config: config} do
      hash = "BCD123DEF456789012345678901234567890ABCD"

      stub_multicall(bypass,
        hash: hash,
        directory: "/downloads/Silo.S03.1080p-GROUP",
        base_path: "/downloads/Silo.S03.1080p-GROUP"
      )

      assert {:ok, status} = Rtorrent.get_status(config, hash)
      assert status.files == ["/downloads/Silo.S03.1080p-GROUP"]
    end

    test "leaves files nil when base_path is not yet allocated",
         %{bypass: bypass, config: config} do
      hash = "CDE123DEF456789012345678901234567890ABCD"

      stub_multicall(bypass, hash: hash, directory: "/downloads", base_path: "")

      assert {:ok, status} = Rtorrent.get_status(config, hash)
      assert status.files == nil
    end

    # d.multicall2 returns one array per torrent, values in the exact order the
    # fields were requested.
    defp stub_multicall(bypass, opts) do
      values = [
        {:string, Keyword.fetch!(opts, :hash)},
        {:string, "Silo.S03E02.1080p.mkv"},
        {:int, 1},
        {:int, 1},
        {:int, 1},
        {:int, 0},
        {:int, 100},
        {:int, 100},
        {:int, 0},
        {:int, 0},
        {:int, 0},
        {:int, 1000},
        {:string, Keyword.fetch!(opts, :directory)},
        {:string, Keyword.fetch!(opts, :base_path)},
        {:int, 1_700_000_000},
        {:int, 1_700_000_100}
      ]

      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <methodResponse><params><param><value><array><data><value><array><data>
      #{Enum.map_join(values, "\n", &xmlrpc_value/1)}
      </data></array></value></data></array></value></param></params></methodResponse>
      """

      Bypass.stub(bypass, "POST", "/RPC2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/xml")
        |> Plug.Conn.resp(200, body)
      end)
    end

    defp xmlrpc_value({:string, v}), do: "<value><string>#{v}</string></value>"
    defp xmlrpc_value({:int, v}), do: "<value><i8>#{v}</i8></value>"
  end

  describe "priority profile resolution (Bypass)" do
    setup do
      bypass = Bypass.open()

      config = %{
        @config
        | host: "localhost",
          port: bypass.port,
          username: nil,
          password: nil
      }

      {:ok, bypass: bypass, config: config}
    end

    # XML-RPC success response indicating load.start succeeded (returned 0).
    @load_ok_response """
    <?xml version="1.0" encoding="UTF-8"?>
    <methodResponse><params><param><value><i4>0</i4></value></param></params></methodResponse>
    """

    test "empty profile omits the d.priority.set command",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/RPC2", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        refute body =~ "d.priority.set"

        conn
        |> Plug.Conn.put_resp_content_type("text/xml")
        |> Plug.Conn.resp(200, @load_ok_response)
      end)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"
      assert {:ok, _hash} = Rtorrent.add_torrent(config, {:magnet, magnet}, priority: :high)
    end

    test "profile override is appended as d.priority.set=N",
         %{bypass: bypass, config: config} do
      config_with_profile = Map.put(config, :priority_profile, %{"high" => 3})

      Bypass.expect(bypass, "POST", "/RPC2", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        assert body =~ "d.priority.set=3"

        conn
        |> Plug.Conn.put_resp_content_type("text/xml")
        |> Plug.Conn.resp(200, @load_ok_response)
      end)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      assert {:ok, _hash} =
               Rtorrent.add_torrent(config_with_profile, {:magnet, magnet}, priority: :high)
    end

    test "no priority option omits the d.priority.set command",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/RPC2", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        refute body =~ "d.priority.set"

        conn
        |> Plug.Conn.put_resp_content_type("text/xml")
        |> Plug.Conn.resp(200, @load_ok_response)
      end)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"
      assert {:ok, _hash} = Rtorrent.add_torrent(config, {:magnet, magnet})
    end
  end
end
