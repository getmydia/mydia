defmodule Mydia.Downloads.Client.RqbitTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Rqbit

  @hash "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

  @config %{
    type: :rqbit,
    host: "localhost",
    port: 3030,
    username: nil,
    password: nil,
    use_ssl: false,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      behaviours = Rqbit.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end

    test "supports only the torrent protocol" do
      assert Rqbit.supported_protocols() == [:torrent]
    end
  end

  describe "unreachable host" do
    setup do
      unreachable = %{@config | host: "nonexistent.invalid", port: 9999}
      {:ok, config: put_in(unreachable, [:options, :connect_timeout], 100)}
    end

    test "test_connection returns a connection error", %{config: config} do
      assert {:error, error} = Rqbit.test_connection(config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "add_torrent returns a connection error", %{config: config} do
      assert {:error, error} =
               Rqbit.add_torrent(config, {:magnet, "magnet:?xt=urn:btih:#{@hash}"})

      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "list_torrents returns a connection error", %{config: config} do
      assert {:error, error} = Rqbit.list_torrents(config, [])
      assert error.type in [:connection_failed, :network_error, :timeout]
    end

    test "pause/resume/remove return connection errors", %{config: config} do
      assert {:error, _} = Rqbit.pause_torrent(config, @hash)
      assert {:error, _} = Rqbit.resume_torrent(config, @hash)
      assert {:error, _} = Rqbit.remove_torrent(config, @hash, delete_files: false)
    end
  end

  describe "test_connection/1 (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "returns ClientInfo on success", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents", fn conn ->
        json_resp(conn, 200, %{"torrents" => []})
      end)

      assert {:ok, info} = Rqbit.test_connection(config)
      assert info.version == "rqbit"
    end

    test "maps 401 to authentication_failed", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents", fn conn ->
        json_resp(conn, 401, %{"error_kind" => "unauthorized", "human_readable" => "unauthorized"})
      end)

      assert {:error, error} = Rqbit.test_connection(config)
      assert error.type == :authentication_failed
    end
  end

  describe "add_torrent/3 (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "adds a magnet with is_url=true and returns the info hash", %{
      bypass: bypass,
      config: config
    } do
      magnet = "magnet:?xt=urn:btih:#{@hash}"

      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["is_url"] == "true"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == magnet
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, magnet})
    end

    test "uploads .torrent bytes raw with is_url=false", %{bypass: bypass, config: config} do
      torrent_bytes = <<1, 2, 3, 4, 5>>

      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["is_url"] == "false"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == torrent_bytes
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:file, torrent_bytes})
    end

    test "passes save_path as output_folder", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["output_folder"] == "/data/movies"
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} =
               Rqbit.add_torrent(config, {:magnet, "magnet:?x"}, save_path: "/data/movies")
    end

    test "omits output_folder when no save_path is given", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "output_folder")
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, "magnet:?x"})
    end

    test "ignores category — no category param is sent to rqbit", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "category")
        refute Map.has_key?(conn.query_params, "tags")
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} =
               Rqbit.add_torrent(config, {:magnet, "magnet:?x"}, category: "movies", tags: ["x"])
    end

    test "treats an already-managed torrent as success", %{bypass: bypass, config: config} do
      # rqbit returns the same shape for AlreadyManaged as for a fresh add.
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        json_resp(conn, 200, add_response(@hash))
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, "magnet:?x"})
    end

    test "when paused: true, adds then issues a pause request", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        json_resp(conn, 200, add_response(@hash))
      end)

      pause_called = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/pause", fn conn ->
        :counters.add(pause_called, 1, 1)
        json_resp(conn, 200, %{})
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, "magnet:?x"}, paused: true)
      assert :counters.get(pause_called, 1) == 1
    end

    test "a failed pause after add is non-fatal", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents", fn conn ->
        json_resp(conn, 200, add_response(@hash))
      end)

      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/pause", fn conn ->
        json_resp(conn, 400, %{"error_kind" => "internal_error", "human_readable" => "nope"})
      end)

      assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, "magnet:?x"}, paused: true)
    end
  end

  describe "get_status/2 state mapping (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "live + finished maps to :seeding at 100% progress", %{bypass: bypass, config: config} do
      stub_details(bypass)

      stub_stats(
        bypass,
        stats(state: "live", finished: true, progress_bytes: 1000, total_bytes: 1000)
      )

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.state == :seeding
      assert status.progress == 100.0
      assert status.id == @hash
    end

    test "live + not finished maps to :downloading with computed progress", %{
      bypass: bypass,
      config: config
    } do
      stub_details(bypass)

      stub_stats(
        bypass,
        stats(state: "live", finished: false, progress_bytes: 500, total_bytes: 1000)
      )

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.state == :downloading
      assert status.progress == 50.0
    end

    test "initializing maps to :checking", %{bypass: bypass, config: config} do
      stub_details(bypass)
      stub_stats(bypass, stats(state: "initializing", finished: false))

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.state == :checking
    end

    test "paused maps to :paused", %{bypass: bypass, config: config} do
      stub_details(bypass)
      stub_stats(bypass, stats(state: "paused", finished: false))

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.state == :paused
    end

    test "error maps to :error", %{bypass: bypass, config: config} do
      stub_details(bypass)
      stub_stats(bypass, stats(state: "error", finished: false))

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.state == :error
    end

    test "converts MiB/s speeds to integer bytes/sec", %{bypass: bypass, config: config} do
      stub_details(bypass)

      stub_stats(
        bypass,
        stats(state: "live", finished: false, progress_bytes: 1, total_bytes: 1000)
        |> Map.put("live", %{
          "download_speed" => %{"mbps" => 12.5},
          "upload_speed" => %{"mbps" => 0.0},
          "time_remaining" => nil
        })
      )

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.download_speed == round(12.5 * 1_048_576)
      assert status.upload_speed == 0
    end

    test "unknown info hash (404) maps to not_found", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents/#{@hash}", fn conn ->
        json_resp(conn, 404, %{
          "error_kind" => "torrent_not_found",
          "human_readable" => "torrent not found"
        })
      end)

      assert {:error, error} = Rqbit.get_status(config, @hash)
      assert error.type == :not_found
    end

    test "populates absolute files from torrent file list under shared output_folder", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect(bypass, "GET", "/torrents/#{@hash}", fn conn ->
        json_resp(conn, 200, %{
          "id" => 0,
          "info_hash" => @hash,
          "name" => "Silo.S03E03.mkv",
          "output_folder" => "/mnt/storage/media/Downloads/rqbit/",
          "files" => [
            %{
              "name" => "Silo.S03E03.mkv",
              "components" => ["Silo.S03E03.mkv"],
              "length" => 100,
              "included" => true
            },
            %{
              "name" => "skip.me.nfo",
              "components" => ["skip.me.nfo"],
              "length" => 10,
              "included" => false
            }
          ]
        })
      end)

      stub_stats(
        bypass,
        stats(state: "live", finished: true, progress_bytes: 100, total_bytes: 100)
      )

      assert {:ok, status} = Rqbit.get_status(config, @hash)
      assert status.save_path == "/mnt/storage/media/Downloads/rqbit/"
      assert status.files == ["/mnt/storage/media/Downloads/rqbit/Silo.S03E03.mkv"]
    end
  end

  describe "list_torrents/2 (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "requests with_stats and parses embedded stats", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["with_stats"] == "true"

        json_resp(conn, 200, %{
          "torrents" => [
            %{
              "id" => 0,
              "info_hash" => @hash,
              "name" => "Movie",
              "output_folder" => "/downloads",
              "stats" => stats(state: "live", finished: true, progress_bytes: 10, total_bytes: 10)
            }
          ]
        })
      end)

      assert {:ok, [status]} = Rqbit.list_torrents(config, [])
      assert status.id == @hash
      assert status.state == :seeding
      assert status.save_path == "/downloads"
    end

    test "category filter is a no-op — all torrents returned", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/torrents", fn conn ->
        json_resp(conn, 200, %{
          "torrents" => [
            %{
              "id" => 0,
              "info_hash" => @hash,
              "name" => "A",
              "output_folder" => "/d",
              "stats" => stats()
            },
            %{
              "id" => 1,
              "info_hash" => "ff",
              "name" => "B",
              "output_folder" => "/d",
              "stats" => stats()
            }
          ]
        })
      end)

      assert {:ok, torrents} = Rqbit.list_torrents(config, category: "anything")
      assert length(torrents) == 2
    end
  end

  describe "remove/pause/resume (Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, config: bypass_config(bypass)}
    end

    test "remove_torrent with delete_files: true hits /delete", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/delete", fn conn ->
        json_resp(conn, 200, %{})
      end)

      assert :ok = Rqbit.remove_torrent(config, @hash, delete_files: true)
    end

    test "remove_torrent without delete_files hits /forget", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/forget", fn conn ->
        json_resp(conn, 200, %{})
      end)

      assert :ok = Rqbit.remove_torrent(config, @hash, delete_files: false)
    end

    test "pause_torrent hits /pause", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/pause", fn conn ->
        json_resp(conn, 200, %{})
      end)

      assert :ok = Rqbit.pause_torrent(config, @hash)
    end

    test "resume_torrent hits /start", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/torrents/#{@hash}/start", fn conn ->
        json_resp(conn, 200, %{})
      end)

      assert :ok = Rqbit.resume_torrent(config, @hash)
    end
  end

  ## Helpers

  defp bypass_config(bypass) do
    %{
      type: :rqbit,
      host: "localhost",
      port: bypass.port,
      username: nil,
      password: nil,
      use_ssl: false,
      options: %{timeout: 5_000, connect_timeout: 2_000}
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp add_response(hash) do
    %{
      "id" => 0,
      "output_folder" => "/downloads/Movie",
      "details" => %{
        "id" => 0,
        "info_hash" => hash,
        "name" => "Movie",
        "output_folder" => "/downloads/Movie",
        "total_pieces" => 100
      }
    }
  end

  defp stats(overrides \\ []) do
    base = %{
      "state" => "live",
      "finished" => false,
      "error" => nil,
      "progress_bytes" => 0,
      "uploaded_bytes" => 0,
      "total_bytes" => 1000,
      "live" => nil
    }

    Map.merge(base, Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  defp stub_details(bypass) do
    Bypass.stub(bypass, "GET", "/torrents/#{@hash}", fn conn ->
      json_resp(conn, 200, %{
        "id" => 0,
        "info_hash" => @hash,
        "name" => "Movie",
        "output_folder" => "/downloads",
        "total_pieces" => 100
      })
    end)
  end

  defp stub_stats(bypass, stats) do
    Bypass.stub(bypass, "GET", "/torrents/#{@hash}/stats/v1", fn conn ->
      json_resp(conn, 200, stats)
    end)
  end
end
